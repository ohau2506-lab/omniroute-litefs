FROM node:20-alpine

# docker-cli: control containers via socket
# docker-cli-compose: enable `docker compose` subcommand (compose plugin)
RUN apk add --no-cache docker-cli docker-cli-compose

WORKDIR /app

# Chỉ copy file cần thiết
COPY elector.js ./

# Không cần npm install — chỉ dùng Node.js built-in modules:
#   https, http, crypto, child_process, os

ENTRYPOINT ["node", "elector.js"]
