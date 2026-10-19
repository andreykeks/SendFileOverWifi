FROM node:22-alpine AS build
WORKDIR /site
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY . .
# Release files can be copied from a build machine with owner-only permissions.
# nginx runs as an unprivileged worker, so public downloads must stay readable.
RUN chmod -R a+rX public
# `src/data/ui.json` is generated from the repository-wide localization catalogue
# before the deployment context is copied to the server.
RUN ASTRO_TELEMETRY_DISABLED=1 ./node_modules/.bin/astro build

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /site/dist /usr/share/nginx/html
EXPOSE 80
