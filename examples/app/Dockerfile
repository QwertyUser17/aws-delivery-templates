# A small static site, enough to try the pipelines end to end.
FROM nginxinc/nginx-unprivileged:1.31-alpine

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080

# deploy-ec2 waits for this to report healthy before it calls a deploy done.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
