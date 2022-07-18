FROM biomedia/dhcp-structural-pipeline:new-mirtk

COPY pipeline_r3.sh /usr/local/src/structural-pipeline/scripts/misc/pipeline.sh
RUN chmod +rx /usr/local/src/structural-pipeline/scripts/misc/pipeline.sh

