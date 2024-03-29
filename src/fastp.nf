#!/usr/bin/env nextflow

nextflow.enable.dsl=2

// Notes:
// Requires that fastp v0.23.4+ is installed

// Example usage:
// nextflow run /lustre/home/tj311/nextflow-scripts/fastp.nf \
//     --reads /lustre/home/tj311/nextflow-scripts/test \
//     --reads_suffix "_{1,2}.fastq.gz" \
//     --esf /lustre/home/tj311/nextflow-scripts/test \
//     --esf_prefix "11171_|11002_|10628_" \
//     --esf_suffix "_R{1,2}_001.fastq.gz" \
//     --adapters /lustre/home/tj311/illumina_adapters.fasta \
//     --outdir /lustre/home/tj311/nextflow-scripts/test \
//     --cpus 16

// Parameters
params.reads = "${PWD}"
params.reads_suffix = "_{1,2}.fastq.gz"
params.esf = "${PWD}"
params.esf_prefix = ""
params.esf_suffix = "_R{1,2}_001.fastq.gz"
params.adapters = "${PWD}/adapters.fasta"
params.outdir = "${PWD}"
params.test = false
params.cpus = 16

// Print parameters to the console
log.info """\
         F A S T P - N F   P I P E L I N E
         ===================================
         Input directory: ${params.reads} ${params.esf}
         Adapter file: ${params.adapters}
         Output directory: ${params.outdir}/trimmed_reads
         Number of threads: ${params.cpus}
         Script version: v0.1
         """
         .stripIndent()

// Define workflow
workflow {

    // Create reads channel
    reads_ch = Channel
        .fromFilePairs("${params.reads}/*${params.reads_suffix}", checkIfExists: false)
        .ifEmpty { 
            println "No paired reads found with the pattern `*${params.reads_suffix}`"
            Channel.empty()
        }

    // Create reads channel for Exeter Sequencing Facility data
    reads_esf_ch = Channel
        .fromFilePairs("${params.esf}/*${params.esf_suffix}", checkIfExists: false)
        .ifEmpty { 
            println "No paired reads found with the pattern `*${params.esf_suffix}`"
            Channel.empty()
        }
        // Modify the sample ID
        .map { pair -> 
            def modified_sample_ID = "${pair[0].replaceAll(/${params.esf_prefix}/, "").replaceAll(/_S[0-9]*/, "")}"
            return tuple(modified_sample_ID, pair[1])
        }

    // Merge read channels into a single channel
    reads_all_ch = reads_ch.concat(reads_esf_ch)

    // Test run to view parameters and contents of reads_ch
    if ( params.test ) {
        reads_all_ch.view()
    }
    // Filter and trim reads using fastp
    else {
        FASTP(reads_all_ch)
    }
}


// FASTP
process FASTP {

    // Directives
    cpus params.cpus
    publishDir "${params.outdir}/trimmed_reads", mode: "copy"

    input:
    tuple val(sample_id), path(reads)

    output:
    // Output file names in the format `sample_ID.fp.fq.gz`
    path("*fp.fq.gz")
    // path("*.html")
    // path("*.json")

    script:
    """
    fastp \
    -i ${reads[0]} \
    -I ${reads[1]} \
    -o ${sample_id}_1.fp.fq.gz \
    -O ${sample_id}_2.fp.fq.gz \
    --adapter_fasta ${params.adapters} \
    --qualified_quality_phred 30 \
    --trim_poly_g \
    --length_required 100 \
    --json ${sample_id}_fastp.json \
    --html ${sample_id}_fastp.html \
    --thread ${task.cpus}
    """
}
