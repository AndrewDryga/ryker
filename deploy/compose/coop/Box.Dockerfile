ARG COOP_BASE_IMAGE=coop-box
FROM ${COOP_BASE_IMAGE}

USER root
COPY ryker-ca.pem /usr/local/share/ca-certificates/ryker-ca.crt
RUN chmod 0644 /usr/local/share/ca-certificates/ryker-ca.crt \
 && update-ca-certificates

USER node
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ryker-ca.crt
