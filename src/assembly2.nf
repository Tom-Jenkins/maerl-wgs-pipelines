#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// Parameters
params.nano_reads = "${PWD}"
params.illumina_reads = "${PWD}"
params.outdir = "${PWD}"
params.cpus = 16

// Print parameters to the console
log.info """\
         A S S E M B L Y - N F   P I P E L I N E
         ===================================
         Input Nanopore directory: ${params.nano_reads}
         Input Illumina directory: ${params.illumina_reads}
         Output directory: ${params.outdir}
         Number of threads: ${params.cpus}
         """
         .stripIndent()


// Define workflow
workflow {

    // Import Nanopore reads and store sample ID in tuple
    nanopore_reads_ch = Channel
        .fromPath("${params.nano_reads}/*.fastq.gz", checkIfExists: false).map {
            tuple ( it.name.split(".fastq.gz")[0], it)
        }
        .ifEmpty { error "No reads matching the pattern `*.fastq.gz`" }
        // .view()

    // Detect and remove adapters using Porechop v0.2.4
    porechop_ch = PORECHOP(nanopore_reads_ch)

    // Assemble reads using Flye
    flye_ch = FLYE(porechop_ch)

    // Correct assembly using Medaka (Nanopore reads)
    medaka_ch = MEDAKA(flye_ch)

    // Polish assembly using Polypolish (Illumina reads)
    polypolish_ch = POLYPOLISH(medaka_ch)

    // Map Nanopore reads (used to build assembly) to assembly (output from Porechop)
    MAP_READS(polypolish_ch)
}

// PORECHOP
process PORECHOP {

    // Directives
    cpus params.cpus
    // errorStrategy "ignore"
    publishDir "${params.outdir}/${sample_id}", mode: "copy", pattern: "*.fq.gz"
    conda "/lustre/home/tj311/software/mambaforge3/envs/porechop"
    
    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("*_1000.fq.gz")

    script:
    """
    porechop -i ${reads} -o ${sample_id}.fq -t ${params.cpus}
    gzip ${sample_id}.fq
    seqkit seq \
        --threads ${params.cpus} \
        --min-len 1000 \
        ${sample_id}.fq.gz \
        -o ${sample_id}_1000.fq.gz
    """
}

// FLYE ASSEMBLY
process FLYE {

    // Directives
    cpus params.cpus
    // errorStrategy "ignore"
    publishDir "${params.outdir}/${sample_id}", mode: "copy", pattern: "*"

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("${sample_id}_assembly.fasta")

    script:
    """
    flye \
        --nano-raw ${reads} \
        --out-dir . \
        --min-overlap 5000 \
        --no-alt-contigs \
        --threads ${params.cpus}
    
    seqkit seq \
        --min-len 1000 \
        --out-file ${sample_id}_assembly.fasta \
        assembly.fasta
    """
}

// MEDAKA
process MEDAKA {

    // Directives
    cpus params.cpus
    // errorStrategy "ignore"
    publishDir "${params.outdir}/${sample_id}", mode: "copy"

    // 1. Flye assembly
    // 2. Reads output from Porechop
    input:
    tuple val(sample_id), path(flye_assembly)

    output:
    tuple val(sample_id), path("consensus.fasta")

    script:
    """
    medaka_consensus \
        -i ${params.outdir}/${sample_id}/${sample_id}_1000.fq.gz \
        -d ${flye_assembly} \
        -o . \
        -m r941_prom_sup_g507 \
        -t ${params.cpus}
    """
}

// POLYPOLISH
process POLYPOLISH {

    // Directives
    cpus params.cpus
    // errorStrategy "ignore"
    publishDir "${params.outdir}/${sample_id}", mode: "copy"

    input:
    tuple val(sample_id), path(medaka_assembly)

    output:
    tuple val(sample_id), path("polished.fasta")

    // Index assembly
    // Align Illumina reads to genome separately (required for polypolish)
    // Execute polypolish
    script:
    """
    bwa-mem2 index ${medaka_assembly}

    bwa-mem2 mem \
        -t ${params.cpus} \
        -a ${medaka_assembly} \
        ${params.illumina_reads}/${sample_id}_trim_R1.fq.gz > alignments_1.sam
    
    bwa-mem2 mem \
        -t ${params.cpus} \
        -a ${medaka_assembly} \
        ${params.illumina_reads}/${sample_id}_trim_R2.fq.gz > alignments_2.sam

    polypolish_insert_filter.py \
        --in1 alignments_1.sam \
        --in2 alignments_2.sam \
        --out1 filtered_1.sam \
        --out2 filtered_2.sam
    
    polypolish \
        ${medaka_assembly} \
        filtered_1.sam \
        filtered_2.sam | \
        sed 's/_polypolish//' > polished.fasta
    """
}

// MAP READS
process MAP_READS {

    // Directives
    cpus params.cpus
    // errorStrategy "ignore"
    publishDir "${params.outdir}/${sample_id}", mode: "copy"

    input:
    tuple val(sample_id), path(polished_assembly)

    output:
    path("polished.sorted.bam")
    path("polished.sorted.bam.stats")

    // Align Porechop output reads using minimap2
    // Filter alignments using samtools
    // -F 2304: remove secondary and supplementary reads
    script:
    """
    minimap2 \
        -t ${params.cpus} \
        -o polished.sam \
        -ax map-ont ${polished_assembly} ${params.outdir}/${sample_id}/${sample_id}_1000.fq.gz

    samtools view -@ ${params.cpus} -F 2304 -b polished.sam > polished.bam

    samtools sort -@ ${params.cpus} polished.bam -o polished.sorted.bam

    rm polished.sam polished.bam

    samtools flagstat -@ ${params.cpus} polished.sorted.bam > polished.sorted.bam.stats
    """
}