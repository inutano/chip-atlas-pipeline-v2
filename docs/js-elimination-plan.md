# Plan: Eliminate InlineJavascriptRequirement from CWL Workflows

## Motivation

CWL's most powerful feature is its **deterministic, declarative nature** — workflows describe *what* to compute, not *how*. InlineJavascriptRequirement breaks this by embedding an imperative language (JavaScript) inside declarative workflow definitions, which:

1. **Requires a JS engine** — cwltool embeds Node.js or SpiderMonkey; a minimal runner shouldn't need this
2. **Breaks determinism** — JS expressions can have side effects and non-obvious behavior
3. **Complicates validation** — static analysis of workflow correctness becomes impossible with arbitrary JS
4. **Slows parsing** — launching a JS interpreter for each expression adds overhead
5. **Reduces portability** — not all CWL runners implement JS identically

Our goal: **zero InlineJavascriptRequirement** across all tools and workflows.

## Current JS Usage and Elimination Strategy

### Category 1: Output file naming — `$(inputs.sample_id).ext`

**Current (JS):**
```yaml
arguments:
  - prefix: -o
    valueFrom: $(inputs.sample_id).bigWig
```

**Fix: Use CWL parameter references (no JS needed)**

CWL v1.2 supports parameter references like `$(inputs.sample_id)` WITHOUT InlineJavascriptRequirement for simple property access. However, string concatenation like `$(inputs.sample_id + ".bigWig")` DOES require JS.

**Solution: Construct the filename in the shell command instead:**
```yaml
arguments:
  - shellQuote: false
    valueFrom: -o $SAMPLE_ID.bigWig
```
Or pass the full output filename as a separate input:
```yaml
inputs:
  output_filename:
    type: string
    inputBinding:
      prefix: -o
```
The workflow caller provides the full filename.

**Affected tools:** bwa-mem2-align, samtools-sort, samtools-fixmate, samtools-markdup, bedtools-genomecov, bedgraphtobigwig, bedtobigbed, deeptools-bamcoverage, fastp, parabricks-fq2bam

### Category 2: Runtime values — `$(runtime.cores)`

**Current (JS):**
```yaml
arguments:
  - prefix: -t
    valueFrom: $(runtime.cores)
```

**Fix:** `$(runtime.cores)` is actually a CWL parameter reference, not JS. It works WITHOUT InlineJavascriptRequirement in most runners. We just need to remove the `InlineJavascriptRequirement` declaration and test.

If a runner doesn't support `$(runtime.*)` without JS, the alternative is to pass thread count as an explicit input:
```yaml
inputs:
  threads:
    type: int
    default: 8
    inputBinding:
      prefix: -t
```

**Affected tools:** bwa-mem2-align, samtools-sort, samtools-fixmate, samtools-markdup, deeptools-bamcoverage, fastp

### Category 3: Conditional steps — `when: $(inputs.bed != null)`

**Current (JS):**
```yaml
bigbed_q05:
  run: bedtobigbed.cwl
  when: $(inputs.bed != null)
```

**Fix: Remove `when` entirely.** Make the tool handle null input gracefully:
```yaml
# In bedtobigbed.cwl — wrap command to check input
arguments:
  - shellQuote: false
    valueFrom: |
      if [ -n "$(inputs.bed)" ]; then
        bedToBigBed ...
      fi
```
Or better: accept `File?` input and have the shell check file existence:
```bash
if [ -f sorted.bed ]; then bedToBigBed sorted.bed ...; fi
```
The output remains `File?` — null when input was null.

**Affected workflows:** option-a, option-a-nomodel, option-a-parabricks, option-b

### Category 4: Read group string construction

**Current (JS):**
```yaml
valueFrom: $("@RG\\tID:" + inputs.sample_id + "\\tSM:" + inputs.sample_id + "\\tPL:ILLUMINA")
```

**Fix: Construct in shell using environment variable or input:**
```yaml
inputs:
  sample_id:
    type: string
arguments:
  - shellQuote: false
    valueFrom: |
      bwa-mem2 mem -R "@RG\tID:SAMPLE\tSM:SAMPLE\tPL:ILLUMINA" ...
```
Where `SAMPLE` is substituted from the input. Alternatively, pass the full RG string as a separate input.

**Affected tools:** bwa-mem2-align, parabricks-fq2bam

### Category 5: Arithmetic — `$(1000000 / inputs.mapped_read_count)`

**Current (JS):**
```yaml
valueFrom: |
  bedtools genomecov -scale $(1000000 / inputs.mapped_read_count) ...
```

**Fix: Do arithmetic in shell:**
```bash
SCALE=$(echo "1000000 / $MAPPED_READS" | bc -l)
bedtools genomecov -scale $SCALE ...
```
Pass `mapped_read_count` as an input and compute in the shell command.

**Affected tools:** bedtools-genomecov

### Category 6: Output parsing — `$(parseInt(self[0].contents.trim()))`

**Current (JS):**
```yaml
outputEval: $(parseInt(self[0].contents.trim()))
```

**Fix: Change tool to output a file instead of parsed value.** The downstream tool reads the file directly in its shell command:
```bash
MAPPED=$(cat mapped_count.txt)
```
This means the count becomes a `File` output instead of `long`, and the consumer reads it in its shell command.

**Affected tools:** samtools-mapped-count

### Category 7: SE/PE branching — `${if (inputs.fastq_rev) ...}`

**Current (JS):**
```yaml
valueFrom: |
  ${
    if (inputs.fastq_rev) {
      return "--in-fq " + fwd + " " + rev + " " + rg;
    } else {
      return "--in-se-fq " + fwd + " " + rg;
    }
  }
```

**Fix: Split into separate tools or handle in shell:**

Option A: Two separate tools (`parabricks-fq2bam-pe.cwl` and `parabricks-fq2bam-se.cwl`) selected at the workflow level.

Option B: Handle in shell with conditional:
```bash
if [ -f "$REV_FASTQ" ]; then
  pbrun fq2bam --in-fq $FWD $REV "$RG" ...
else
  pbrun fq2bam --in-se-fq $FWD "$RG" ...
fi
```

**Affected tools:** parabricks-fq2bam, fastp (--out2 conditional)

### Category 8: Suffix appending in workflows — `valueFrom: $(self).05`

**Current (JS):**
```yaml
sample_id:
  source: sample_id
  valueFrom: $(self).05
```

**Fix: Use separate string inputs instead of JS concatenation:**
```yaml
inputs:
  sample_id_q05:
    type: string
    doc: "Sample ID with q05 suffix, e.g. SRX12345678.05"
```
The caller provides pre-constructed names. Or run three separate workflow instances with different sample IDs.

**Affected workflows:** All (option-a, option-b, parabricks)

## Implementation Order

1. **Categories 2, 1** (runtime.cores, output naming) — most files, low risk
2. **Category 5, 6** (arithmetic, output parsing) — bedtools-genomecov, samtools-mapped-count
3. **Category 4** (read group) — bwa-mem2, parabricks
4. **Category 7** (SE/PE branching) — parabricks, fastp
5. **Category 3** (when conditionals) — workflows
6. **Category 8** (suffix appending) — workflows

## Testing

After each category, validate with `cwltool --validate` and run on a test sample (sacCer3 SRX22049197) to verify identical output.

## Impact on Custom CWL Runner

With JS eliminated, the custom runner only needs:
- YAML parser (for CWL documents and input objects)
- Simple `$(inputs.X)` and `$(runtime.X)` parameter reference resolution
- `File`/`Directory` type handling
- `scatter`/`scatterMethod` support
- Singularity/Docker container invocation
- Job scheduling (SLURM/SGE/local)

No JavaScript engine required.
