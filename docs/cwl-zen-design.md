# CWL Zen: Minimal CWL Runner Design

## Philosophy

**"The workflow language handles plumbing, bash handles logic."**

CWL Zen is a minimal, fast CWL runner that supports a well-defined subset of CWL v1.2. It eliminates the need for a JavaScript engine by keeping the CWL layer purely declarative and pushing all computational logic to shell commands.

### Core Principles

1. **Single run** — execute one workflow on one input. No batch, no scheduler integration.
2. **No JavaScript** — parameter references only (`$(inputs.X)`, `$(runtime.X)`), no `InlineJavascriptRequirement`
3. **Singularity-native** — first-class Singularity/Apptainer support
4. **Fast startup** — minimal overhead, no dependency resolution beyond YAML parsing
5. **Ecosystem of utils** — batch execution, job dispatch, provenance are separate tools, not part of the runner

### Division of Responsibility

| Concern | Handled by |
|---------|-----------|
| Input/output wiring between steps | CWL Zen runner |
| Step dependency resolution (DAG) | CWL Zen runner |
| Container invocation | CWL Zen runner |
| File staging and collection | CWL Zen runner |
| Conditionals, arithmetic, string manipulation | Shell commands (inside tools) |
| Batch execution across samples | External (AI agent, bash loop, scheduler script) |
| Job scheduling (SLURM/SGE/PBS) | External dispatch scripts |
| Provenance / RO-Crate generation | External util |

## Supported CWL v1.2 Subset

### Classes

| Class | Supported | Notes |
|-------|-----------|-------|
| `CommandLineTool` | Yes | Core |
| `Workflow` | Yes | Core |
| `ExpressionTool` | Yes | Shell-based (see below) |

### CommandLineTool Features

| Feature | Supported | Notes |
|---------|-----------|-------|
| `baseCommand` | Yes | |
| `arguments` | Yes | With parameter references |
| `inputs` with `inputBinding` | Yes | `prefix`, `position`, `separate`, `shellQuote` |
| `outputs` with `outputBinding` | Yes | `glob` with parameter references |
| `stdout` | Yes | |
| `stderr` | Yes | |
| `stdin` | Yes | |
| `successCodes` | Yes | |
| `requirements.DockerRequirement` | Yes | `dockerPull` only, executed via Singularity |
| `requirements.ShellCommandRequirement` | Yes | |
| `requirements.ResourceRequirement` | Yes | `coresMin`, `ramMin` → passed to scheduler |
| `requirements.NetworkAccess` | Yes | |
| `requirements.InitialWorkDirRequirement` | Yes | |
| `requirements.EnvVarRequirement` | Yes | |
| `hints.DockerRequirement` | Yes | Same as requirements |
| `requirements.InlineJavascriptRequirement` | **No** | By design |

### Workflow Features

| Feature | Supported | Notes |
|---------|-----------|-------|
| `steps` with `in`/`out` | Yes | Core wiring |
| `outputSource` | Yes | |
| `scatter` | Yes | Single input or multiple with `dotproduct` |
| `scatterMethod: dotproduct` | Yes | |
| `scatterMethod: flat_crossproduct` | No | Rarely needed |
| `scatterMethod: nested_crossproduct` | No | Rarely needed |
| `when` | **No** | Push conditionals to shell |
| `SubworkflowFeatureRequirement` | Yes | |
| `MultipleInputFeatureRequirement` | Yes | `merge_flattened`, `pickValue` |
| `StepInputExpressionRequirement` | **No** | Not needed without JS |

### Type System

| Type | Supported |
|------|-----------|
| `null` | Yes |
| `boolean` | Yes |
| `int` / `long` | Yes |
| `float` / `double` | Yes |
| `string` | Yes |
| `File` | Yes (with `secondaryFiles`, `format`, `checksum`) |
| `Directory` | Yes |
| `File?`, `string?`, etc. | Yes (optional types) |
| `File[]`, `string[]`, etc. | Yes (array types) |
| `record` | Yes |
| `enum` | Yes |
| `Any` | No |

### Parameter References (NOT JavaScript)

CWL Zen supports parameter references as simple string interpolation:

```
$(inputs.sample_id)         → value of sample_id input
$(inputs.bam.path)          → file path of bam input
$(inputs.bam.basename)      → filename without directory
$(inputs.bam.nameroot)      → filename without extension
$(inputs.bam.nameext)       → file extension
$(inputs.bam.size)          → file size in bytes
$(runtime.cores)            → allocated CPU cores
$(runtime.ram)              → allocated RAM in MB
$(runtime.outdir)           → output directory path
$(runtime.tmpdir)           → temporary directory path
$(self)                     → current value (in valueFrom context)
$(self[0].contents)         → file contents (with loadContents)
```

**String interpolation rules:**
- `$(inputs.x)` anywhere in a string is replaced with the value
- `"prefix_$(inputs.x)_suffix"` works — no JS needed for concatenation
- Nested property access works: `$(inputs.file.path)`
- No arithmetic, no function calls, no conditionals

### ExpressionTool (Shell-based)

CWL Zen reimagines ExpressionTool as a lightweight shell transformation:

```yaml
class: ExpressionTool
requirements:
  ShellCommandRequirement: {}

expression:
  shellCommand: |
    echo $(inputs.mapped_count) | awk '{printf "%.10f\n", 1000000/$1}'

inputs:
  mapped_count:
    type: long

outputs:
  scale_factor:
    type: string
```

The shell command receives inputs as parameter references, stdout is captured as the output. This replaces JS expressions with shell commands — keeping the transformation explicit and debuggable.

**Note:** This is a CWL Zen extension, not standard CWL. Standard ExpressionTool uses JS `expression` field. CWL Zen translates `expression` to a shell command — documents using this feature are not portable to cwltool without modification.

## Architecture

```
cwl-zen
├── parser/
│   ├── cwl_document.rs    — parse CWL YAML into typed structs
│   ├── param_ref.rs       — resolve $(inputs.X), $(runtime.X)
│   └── types.rs           — CWL type system
├── executor/
│   ├── dag.rs             — build step dependency graph
│   ├── runner.rs          — execute steps in topological order
│   ├── container.rs       — Singularity/Docker invocation
│   └── staging.rs         — file staging (input mount, output collection)
├── scatter/
│   └── dotproduct.rs      — scatter implementation
└── main.rs                — CLI entry point
```

### CLI Interface

```bash
# Basic run
cwl-zen run workflow.cwl input.yml

# With output directory
cwl-zen run workflow.cwl input.yml --outdir ./results

# With Singularity (default)
cwl-zen run workflow.cwl input.yml --container singularity

# With Docker
cwl-zen run workflow.cwl input.yml --container docker

# Validate only
cwl-zen validate workflow.cwl

# Print DAG
cwl-zen dag workflow.cwl

# Pack workflow (resolve all references)
cwl-zen pack workflow.cwl
```

### Execution Flow

```
1. Parse CWL document(s)
2. Parse input YAML
3. Resolve all parameter references
4. Build step DAG from input/output wiring
5. For each step in topological order:
   a. Stage input files into working directory
   b. Construct command line (baseCommand + arguments + inputs)
   c. Run command in container (Singularity/Docker)
   d. Collect output files (match glob patterns)
   e. Pass outputs to downstream steps
6. Collect final workflow outputs to --outdir
7. Exit with success/failure code
```

## Ecosystem (separate tools, not part of runner)

### cwl-zen-dispatch

Job scheduler submission scripts:

```bash
# Submit a single workflow run to SLURM
cwl-zen-dispatch slurm workflow.cwl input.yml \
  --cpus 8 --mem 32G --time 4:00:00

# Generates and submits:
# sbatch --cpus-per-task=8 --mem=32G --time=4:00:00 \
#   --wrap="cwl-zen run workflow.cwl input.yml --outdir ..."
```

### cwl-zen-batch

Parallel sample processing:

```bash
# Process all samples in a TSV
cwl-zen-batch workflow.cwl samples.tsv \
  --template input-template.yml \
  --scheduler slurm \
  --max-concurrent 100
```

### cwl-zen-prov

RO-Crate provenance generation:

```bash
# Generate RO-Crate from a completed run
cwl-zen-prov generate ./results/
```

### cwl-zen-lint

Validate CWL Zen compatibility:

```bash
# Check if a CWL document is CWL Zen compatible (no JS)
cwl-zen-lint workflow.cwl
# Output: PASS / FAIL with specific JS usage locations
```

## Language Choice

**Rust** is the recommended implementation language:
- Single static binary — no runtime dependencies, easy to deploy on HPC
- Fast startup time — important for single-run model
- Strong type system — matches CWL's type system well
- YAML parsing via `serde_yaml`
- Process spawning via `std::process::Command`

**Alternative: Go** — also produces static binaries, simpler concurrency model, but weaker type system.

## Relationship to CWL v1.2

CWL Zen documents are a **strict subset** of CWL v1.2 (with one exception: shell-based ExpressionTool). Any CWL Zen document should also be valid under cwltool (minus the ExpressionTool extension). The reverse is not true — cwltool documents with JS are not CWL Zen compatible.

A `cwl-zen-lint` tool can validate this: it checks for InlineJavascriptRequirement, JS expressions in valueFrom/when/outputEval, and reports incompatibilities.
