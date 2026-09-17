FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends monit && \
    rm -rf /var/lib/apt/lists/*

COPY config/monitrc /etc/monit/monitrc
RUN chmod 600 /etc/monit/monitrc

HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
    CMD monit status || exit 1

# -I: フォアグラウンドで実行（Dockerのプロセスモデルに合わせるため daemonize しない）
CMD ["monit", "-Ic", "/etc/monit/monitrc"]
