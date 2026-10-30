FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends monit curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY config/monitrc /etc/monit/monitrc
RUN chmod 600 /etc/monit/monitrc

COPY bin/hc-notify bin/docker-entrypoint /usr/local/bin/

HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
    CMD monit status || exit 1

ENTRYPOINT ["docker-entrypoint"]

# -I: フォアグラウンドで実行（Dockerのプロセスモデルに合わせるため daemonize しない）
CMD ["monit", "-Ic", "/etc/monit/monitrc"]
