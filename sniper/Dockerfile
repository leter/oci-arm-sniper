FROM python:3.12-slim-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir oci-cli

COPY sniper.sh /usr/local/bin/sniper.sh
RUN chmod +x /usr/local/bin/sniper.sh

ENV SNIPER_LOG_DIR=/var/log/sniper
VOLUME ["/var/log/sniper"]

CMD ["/usr/local/bin/sniper.sh", "--loop"]
