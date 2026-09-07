FROM node:20-alpine
WORKDIR /app
COPY package.json ./
# no dependencies — built-ins only; keep npm ci cheap and cache-friendly
RUN npm install --omit=dev || true
COPY server.js ./
COPY public ./public
EXPOSE 5173
CMD ["node", "server.js"]
