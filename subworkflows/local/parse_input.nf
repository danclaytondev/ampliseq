//
// Check input samplesheet or folder and get read channels
//

params.options = [:]

// Function to get list of [ meta, [ fastq_1, fastq_2 ] ]
def parse_samplesheet(LinkedHashMap row, single_end) {
    //Check if manifest contains column sampleID  & forwardReads
    if (row.sampleID == null || row.forwardReads == null) {
        exit 1, "ERROR: Please check input samplesheet -> Column 'sampleID' and 'forwardReads' are required but not detected."
    }
    //Check if manifest contains a column for reverse reads
    if (row.reverseReads == null && !single_end) {
        exit 1, "ERROR: Please check input samplesheet -> Column 'reverseReads' is missing. In case you do have only single ended reads, please specify '--single_end', '--pacbio', or '--iontorrent'."
    }
    //read meta info
    def meta = [:]
    meta.id           = row.sampleID
    meta.single_end   = single_end.toBoolean()
    meta.run          = row.run == null ? "1" : row.run
    //read data info
    def array = []
    if (!file(row.forwardReads).exists()) {
        exit 1, "ERROR: Please check input samplesheet -> Forward read FastQ file does not exist!\n${row.forwardReads}"
    }
    if (meta.single_end) {
        array = [ meta, [ file(row.forwardReads) ] ]
    } else {
        if (!file(row.reverseReads).exists()) {
            exit 1, "ERROR: Please check input samplesheet -> Reverse read FastQ file does not exist!\n${row.reverseReads}"
        }
        array = [ meta, [ file(row.forwardReads), file(row.reverseReads) ] ]
    }
    return array
}

workflow PARSE_INPUT {
    take:
    input // file.tsv or folder
    is_fast_input
    single_end
    multiple_sequencing_runs
    extension

    main:
    if ( is_fast_input ) {
        // Fasta input directely for classification
        ch_fasta = Channel.fromPath(input, checkIfExists: true)
        ch_reads = Channel.empty()
    } else {
        ch_fasta = Channel.empty()

        if ( input.toString().toLowerCase().endsWith("tsv") ) {
            // Sample sheet input

            tsvFile = file(input).getName()
            // extracts read files from TSV and distribute into channels
            Channel
                .fromPath(input)
                .ifEmpty {exit 1, log.info "Cannot find path file ${tsvFile}"}
                .splitCsv(header:true, sep:'\t')
                .map { parse_samplesheet(it, single_end) }
                .set { ch_reads }
        } else {
            // Folder input

            //Check folders in folder when multiple_sequencing_runs
            folders = multiple_sequencing_runs ? "/*" : ""
            if ( single_end ) {
                //Get files - single end
                Channel
                    .fromPath( input + folders + extension )
                    .ifEmpty { exit 1, "Cannot find any reads matching: \"${input}${extension}\"\nPlease revise the input folder (\"--input\"): \"${input}\"\nand the input file pattern (\"--extension\"): \"${extension}\"\nIf you have multiple sequencing runs, please add \"--multiple_sequencing_runs\".\nNB: Path needs to be enclosed in quotes!" }
                    .map { read ->
                            def meta = [:]
                            meta.id           = read.baseName.toString().indexOf("_") != -1 ? read.baseName.toString().take(read.baseName.toString().indexOf("_")) : read.baseName
                            meta.single_end   = single_end.toBoolean()
                            meta.run          = multiple_sequencing_runs ? read.take(read.findLastIndexOf{"/"})[-1] : "1"
                            [ meta, read ] }
                    .set { ch_reads }
            } else {
                //Get files - paired end
                Channel
                    .fromFilePairs( input + folders + extension, size: 2 )
                    .ifEmpty { exit 1, "Cannot find any reads matching: \"${input}${extension}\"\nPlease revise the input folder (\"--input\"): \"${input}\"\nand the input file pattern (\"--extension\"): \"${extension}\"\nIf you have multiple sequencing runs, please add \"--multiple_sequencing_runs\".\nNB: Path needs to be enclosed in quotes!" }
                    .map { name, reads ->
                            def meta = [:]
                            meta.id           = name.toString().indexOf("_") != -1 ? name.toString().take(name.toString().indexOf("_")) : name
                            meta.single_end   = single_end.toBoolean()
                            meta.run          = multiple_sequencing_runs ? reads[0].take(reads[0].findLastIndexOf{"/"})[-1] : "1"
                            [ meta, reads ] }
                    .set { ch_reads }
            }
            if (multiple_sequencing_runs) {
                //Get folder information
                ch_reads
                    .flatMap { meta, reads -> [ meta.run ] }
                    .unique()
                    .set { ch_folders }
                //Report folders with sequencing files
                ch_folders
                    .collect()
                    .subscribe {
                        String folders = it.toString().replace("[", "").replace("]","")
                        log.info "\nFound the folder(s) \"$folders\" containing sequencing read files matching \"${extension}\" in \"${input}\".\n" }
                //Stop if folder count is 1 and multiple_sequencing_runs
                ch_folders
                    .count()
                    .subscribe { if ( it == 1 ) exit 1, "Found only one folder with read data but \"--multiple_sequencing_runs\" was specified. Please review data input." }
            }
        }

        //Check whether all sampleID = meta.id are unique
        ch_reads
            .map { meta, reads -> [ meta.id ] }
            .toList()
            .subscribe {
                if( it.size() != it.unique().size() ) {
                    ids = it.take(10);
                    exit 1, "Please review data input, sample IDs are not unique! First IDs are $ids"
                }
            }

        //Check that no dots "." are in sampleID
        ch_reads
            .map { meta, reads -> [ meta.id ] }
            .subscribe { if ( "$it".contains(".") ) exit 1, "Please review data input, sampleIDs may not contain dots, but \"$it\" does." }
    }

    emit:
    reads   = ch_reads
    fasta   = ch_fasta
}
