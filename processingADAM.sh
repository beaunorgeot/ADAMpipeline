


set -e
set -x
set -o pipefail

export ADAM_DRIVER_MEMORY="55g"
export ADAM_EXECUTOR_MEMORY="55g"
export SPARK_HOME="/root/spark"
export ADAM_OPTS="--conf spark.eventLog.enabled=true --conf spark.worker.timeout=500"
#export ADAM_OPTS="--conf spark.shuffle.service.enable=true"

Time=/usr/bin/time

# start MR nodes
./ephemeral-hdfs/bin/stop-all.sh
./ephemeral-hdfs/bin/start-all.sh

# make a directory in hdfs
./ephemeral-hdfs/bin/hadoop fs -mkdir .

# download dbsnp file
cd /mnt
wget ftp://ftp-trace.ncbi.nih.gov/1000genomes/ftp/technical/reference/dbsnp132_20101103.vcf.gz
gunzip dbsnp132_20101103.vcf.gz
mv dbsnp132_20101103.vcf dbsnp_132.vcf
cd ~
./ephemeral-hdfs/bin/hadoop fs -put /mnt/dbsnp_132.vcf .

# pull NA12878 from 1000g using s3-downloader
~/spark/bin/spark-submit ~/spark-s3-downloader-0.1-SNAPSHOT.jar \
    s3://bd2k-test-data/NA12878.mapped.ILLUMINA.bwa.CEU.high_coverage_pcr_free.20130906.bam \
    ${hdfs_root}/user/${USER}/NA12878.bam

# convert to adam, and remove bam
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/NA12878.bam \
    ${hdfs_root}/user/${USER}/NA12878.adam

./ephemeral-hdfs/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/NA12878.bam

# run flagstat
$Time ${ADAM_HOME}/bin/adam-submit flagstat \
    ${hdfs_root}/user/${USER}/NA12878.adam \
    > flagstat.report 2>&1

# sort the file
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/NA12878.adam \
    ${hdfs_root}/user/${USER}/NA12878.sort.adam \
    -sort_reads \
    > sort.report 2>&1

#remove .adam input file
./ephemeral-hdfs/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/NA12878.adam

# mark duplicate reads
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/NA12878.sort.adam \
    ${hdfs_root}/user/${USER}/NA12878.mkdup.adam \
    -mark_duplicate_reads \
    > markDups.report 2>&1

#remove .sort.adam input file
./ephemeral-hdfs/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/NA12878.sort.adam

# convert known snps file to adam variants file
$Time ${ADAM_HOME}/bin/adam-submit vcf2adam \
    ${hdfs_root}/user/${USER}/dbsnp_132.vcf \
    ${hdfs_root}/user/${USER}/dbsnp_132.var.adam \
    -onlyvariants \
    > convert_known_snps_2adam.report 2>&1

#remove known snps vcf
./ephemeral-hdfs/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/dbsnp_132.vcf

# realign indels
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/NA12878.mkdup.adam \
    ${hdfs_root}/user/${USER}/NA12878.ri.adam \
    -realign_indels \
    > realignIndels.report 2>&1

#remove mkdup.adam input
./ephemeral-hdfs/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/NA12878.mkdup.adam

# recalibrate quality scores
$Time ${ADAM_HOME}/bin/adam-submit transform \
    ${hdfs_root}/user/${USER}/NA12878.ri.adam \
    ${hdfs_root}/user/${USER}/NA12878.bqsr.adam \
    -recalibrate_base_qualities \
    -known_snps ${hdfs_root}/user/${USER}/dbsnp_132.var.adam \
    > BQSR.report 2>&1


./ephemeral-hdfs/bin/hadoop fs -rmr \
    ${hdfs_root}/user/${USER}/dbsnp_132.var.adam

#HERE BEGINS VARIANT CALLING STEPS USING .bqsr.adam as the input


