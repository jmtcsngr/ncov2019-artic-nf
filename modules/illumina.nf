process readTrimming {
    /**
    * Trims paired fastq using trim_galore (https://github.com/FelixKrueger/TrimGalore)
    * @input tuple(sampleName, path(forward), path(reverse))
    * @output trimgalore_out tuple(sampleName, path("*_val_1.fq.gz"), path("*_val_2.fq.gz"))
    */

    tag { sampleName }

    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: '*_val_{1,2}.fq.gz', mode: 'copy'

    cpus 2

    input:
    tuple(sampleName, path(forward), path(reverse))

    output:
    tuple(sampleName, path("*_val_1.fq.gz"), path("*_val_2.fq.gz")) optional true

    script:
    """
    if [[ \$(gunzip -c ${forward} | head -n4 | wc -l) -eq 0 ]]; then
      exit 0
    else
      trim_galore --paired $forward $reverse
    fi
    """
}

process indexReference {
    /**
    * Indexes reference fasta file in the scheme repo using bwa.
    */

    tag { ref }

    input:
        path(ref)

    output:
        tuple path('ref.fa'), path('ref.fa.*')

    script:
        """
        ln -s ${ref} ref.fa
        bwa index ref.fa
        """
}

process readMapping {
    /**
    * Maps trimmed paired fastq using BWA (http://bio-bwa.sourceforge.net/)
    * Uses samtools to convert to BAM, sort and index sorted BAM (http://www.htslib.org/doc/samtools.html)
    * @input 
    * @output 
    */

    tag { sampleName }

    label 'largecpu'

    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: "${sampleName}.sorted.bam", mode: 'copy'

    input:
        tuple sampleName, path(forward), path(reverse), path(ref), path("*")

    output:
        tuple(sampleName, path("${sampleName}.sorted.bam"))

    script:
      """
      bwa mem -t ${task.cpus} ${ref} ${forward} ${reverse} | \
      samtools sort -o ${sampleName}.sorted.bam
      """
}

process trimPrimerSequences {

    tag { sampleName }

    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: "${sampleName}.mapped.bam", mode: 'copy'
    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: "${sampleName}.mapped.primertrimmed.sorted.bam", mode: 'copy'

    input:
    tuple sampleName, path(bam), path(bedfile)

    output:
    tuple sampleName, path("${sampleName}.mapped.bam"), emit: mapped
    tuple sampleName, path("${sampleName}.mapped.primertrimmed.sorted.bam" ), emit: ptrim

    script:
      ivarCmd = params.allowNoprimer ? "ivar trim -e" : "ivar trim"
      
      samtoolsIvarCmd = params.tlenFilter ?
                            "samtools view -o ${sampleName}.filtered.mapped.bam -U ${sampleName}.bad.mapped.bam -e '!flag.munmap && (tlen > 300 || tlen < -300)' -F 2048 ${sampleName}.mapped.bam ; samtools index ${sampleName}.filtered.mapped.bam ; ${ivarCmd} -i ${sampleName}.filtered.mapped.bam -b ${bedfile} -m ${params.illuminaKeepLen} -q ${params.illuminaQualThreshold} -p ivar.out"
                            :
                            "samtools index ${sampleName}.mapped.bam; ${ivarCmd} -i ${sampleName}.mapped.bam -b ${bedfile} -m ${params.illuminaKeepLen} -q ${params.illuminaQualThreshold} -p ivar.out"
   
    if ( params.cleanBamHeader )

           """
           samtools reheader --no-PG  -c 'sed "s/${sampleName}/sample/g"' ${bam} | \
           samtools view -F4 -o sample.mapped.bam
           mv sample.mapped.bam ${sampleName}.mapped.bam
           ${samtoolsIvarCmd}
           samtools reheader --no-PG  -c 'sed "s/${sampleName}/sample/g"' ivar.out.bam | \
           samtools sort -o sample.mapped.primertrimmed.sorted.bam
           mv sample.mapped.primertrimmed.sorted.bam ${sampleName}.mapped.primertrimmed.sorted.bam
           """
  
    else
        
           """
           samtools view -F4 -o ${sampleName}.mapped.bam ${bam}
           ${samtoolsIvarCmd}
           samtools sort -o ${sampleName}.mapped.primertrimmed.sorted.bam ivar.out.bam
           """
 
}

process callVariants {

    tag { sampleName }

    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: "${sampleName}.variants.tsv", mode: 'copy'

    input:
    tuple(sampleName, path(bam), path(ref))

    output:
    tuple sampleName, path("${sampleName}.variants.tsv"), emit: variants

    script:
        """
        samtools mpileup -A -d 0 --reference ${ref} -B -Q 0 ${bam} |\
        ivar variants -r ${ref} -m ${params.ivarMinDepth} -p ${sampleName}.variants -q ${params.ivarMinVariantQuality} -t ${params.ivarMinFreqThreshold}
        """
}

process makeConsensus {

    tag { sampleName }

    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: "${sampleName}.primertrimmed.consensus.fa", mode: 'copy'

    input:
        tuple(sampleName, path(bam))

    output:
        tuple(sampleName, path("${sampleName}.primertrimmed.consensus.fa"))

    script:
        """
        samtools mpileup -aa -A -B -d ${params.mpileupDepth} -Q0 ${bam} | \
        ivar consensus -t ${params.ivarFreqThreshold} -m ${params.ivarMinDepth} \
        -n N -p ${sampleName}.primertrimmed.consensus
        """
}

process makeConsensusAMD {

    tag { sampleName }

    publishDir "${params.outdir}/${task.process.replaceAll(":","_")}", pattern: "${sampleName}.amd.primertrimmed.consensus.fa", mode: 'copy'

    input:
        tuple(sampleName, path(bam))

    output:
        tuple(sampleName, path("${sampleName}.amd.primertrimmed.consensus.fa"))

    script:
        """
        samtools mpileup -aa -A -B -d ${params.mpileupDepth} -Q0 ${bam} | \
        ivar consensus -t ${params.ivarFreqThreshold} -m ${params.ivarAlternativeMinDepth} \
        -n N -p ${sampleName}.amd.primertrimmed.consensus
        """
}


process cramToFastq {
    /**
    * Converts CRAM to fastq (http://bio-bwa.sourceforge.net/)
    * Uses samtools to convert to CRAM, to FastQ (http://www.htslib.org/doc/samtools.html)
    * @input
    * @output
    */

    input:
        tuple sampleName, file(cram)

    output:
        tuple sampleName, path("${sampleName}_1.fastq.gz"), path("${sampleName}_2.fastq.gz")

    script:
        """
        samtools collate -u ${cram} -o tmp.bam
        samtools fastq -1 ${sampleName}_1.fastq.gz -2 ${sampleName}_2.fastq.gz tmp.bam
        rm tmp.bam
        """
}

