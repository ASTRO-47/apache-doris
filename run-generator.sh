#!/bin/bash

# Build the data generator image
docker build -t doris-data-generator ./data-generator

# Run the data generator
docker run -d \
  --name doris-data-generator \
  --network apache-dori_doris_net \
  -e DORIS_FE_HOST=172.20.80.2 \
  -e DORIS_FE_PORT=9030 \
  -e DORIS_USER=root \
  -e DORIS_PASSWORD= \
  -e EVENTS_PER_SECOND=10 \
  doris-data-generator

echo "Data generator started! View logs with:"
echo "docker logs -f doris-data-generator"
