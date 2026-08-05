FROM ghcr.io/cirruslabs/flutter:stable AS build

ARG API_BASE_URL=http://localhost:8000

WORKDIR /srv/opsatlas/client

COPY client/pubspec.yaml /srv/opsatlas/client/pubspec.yaml
COPY client/analysis_options.yaml /srv/opsatlas/client/analysis_options.yaml

RUN flutter config --enable-web && flutter pub get

COPY client/ /srv/opsatlas/client/

RUN flutter build web --release --dart-define=API_BASE_URL=${API_BASE_URL}

FROM nginx:latest

RUN apt-get update \
	&& apt-get install -y --no-install-recommends wget \
	&& rm -rf /var/lib/apt/lists/*

COPY docker/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /srv/opsatlas/client/build/web/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
