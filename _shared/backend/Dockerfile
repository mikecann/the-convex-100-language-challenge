FROM node:22.18.0-bookworm-slim@sha256:752ea8a2f758c34002a0461bd9f1cee4f9a3c36d48494586f60ffce1fc708e0e

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY tsconfig.json ./
COPY convex ./convex

CMD ["sh", "-lc", "npm run deploy:once && npm run typecheck"]
