FROM docker.io/library/node:24-alpine
WORKDIR /app
COPY server.js .
USER node
EXPOSE 9000
CMD ["node", "server.js"]
