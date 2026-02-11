FROM apache/doris:4.0.2

# Set Doris home explicitly (already exists in the image, but be explicit)
ENV DORIS_HOME=/opt/apache-doris

# Fix network binding for single-node / Docker
RUN echo "priority_networks = 127.0.0.1/32" >> $DORIS_HOME/fe/conf/fe.conf \
 && echo "priority_networks = 127.0.0.1/32" >> $DORIS_HOME/be/conf/be.conf

# Doris 4.x requires swap disabled.
# In Docker, swap is already isolated, this just prevents BE exit.
RUN echo "enable_swap = false" >> $DORIS_HOME/be/conf/be.conf

# Expose standard Doris ports
EXPOSE 8030 9030 8040 9050 9060

# Start FE + BE (single-node dev mode)
CMD bash -c "\
  ulimit -n 655350 && \
  $DORIS_HOME/fe/bin/start_fe.sh && \
  sleep 5 && \
  $DORIS_HOME/be/bin/start_be.sh && \
  tail -f $DORIS_HOME/fe/log/fe.log"

iceberg,delta parket.
scaling, les types, hello generer des evements,   
CDM, 