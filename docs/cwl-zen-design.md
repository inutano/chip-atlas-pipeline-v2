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
| `ExpressionTool` | **No** | Push all transformations to shell inside CommandLineTools |

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

### ExpressionTool — Not Supported

ExpressionTool is excluded from CWL Zen. All data transformations between steps should be done inside CommandLineTools using shell commands.

**Example: RPM scale factor calculation**

Instead of an ExpressionTool that computes `1000000 / mapped_reads`, embed the calculation in the consuming tool:

```yaml
# samtools-mapped-count.cwl outputs a File (not a parsed int)
outputs:
  count_file:
    type: File
    outputBinding:
      glob: mapped_count.txt

# bedtools-genomecov.cwl reads the file in its shell command
arguments:
  - shellQuote: false
    valueFrom: |
      SCALE=$(awk '{printf "%.10f", 1000000/$1}' $(inputs.count_file.path))
      bedtools genomecov -bg -ibam $(inputs.bam.path) -scale $SCALE ...
```

**Design rationale:**
- Every transformation is inside a CommandLineTool — one execution model, not two
- Shell commands are explicit, debuggable, and don't need a special interpreter
- Keeps the runner simpler — no need to handle a third class type
- If ExpressionTool is needed in the future, it can be added back as a shell-based extension

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

CWL Zen documents are a **strict subset** of CWL v1.2. Any CWL Zen document is valid CWL v1.2 and can be executed by cwltool or any compliant runner. The reverse is not true — CWL documents with InlineJavascriptRequirement or ExpressionTool are not CWL Zen compatible.

`cwl-zen-lint` validates compatibility by checking for:
- InlineJavascriptRequirement
- ExpressionTool usage
- JS expressions in valueFrom/when/outputEval
- Unsupported features (nested_crossproduct, etc.)
