FROM node:22.18.0-bookworm-slim@sha256:752ea8a2f758c34002a0461bd9f1cee4f9a3c36d48494586f60ffce1fc708e0e

WORKDIR /harness
COPY _shared/harness/package.json _shared/harness/package-lock.json ./
RUN npm ci --ignore-scripts
COPY _shared/harness/scripts ./scripts
COPY _shared/harness/reference-js ./reference-js
COPY _shared/schemas /schemas

USER node
CMD ["npm", "run", "validate"]
