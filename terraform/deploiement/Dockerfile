# Image du service hébergé : runeride-envoi (fonction Lambda, grâce à l'adaptateur web de Lambda),
# runeride-worker et l'outil d'analyse runeride-tool (tâche Fargate), avec ffmpeg.
# Contexte de construction : le dossier rust/ du dépôt.
#   docker build -f terraform/deploiement/Dockerfile -t runeride-cloud rust/

FROM rust:1-bookworm AS construction
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY core core
COPY server server
COPY render render
COPY cloud-service cloud-service
# l'outil d'analyse vient du cœur ; le moteur GPU (render/) n'est pas compilé ici
RUN cargo build --release --locked -p runeride-core --bin runeride-tool
RUN cargo build --release --locked --manifest-path cloud-service/Cargo.toml

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ffmpeg && rm -rf /var/lib/apt/lists/*
# Adaptateur web de Lambda : dans une fonction, il confie les requêtes au serveur HTTP ; ailleurs, il ne fait rien.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter
COPY --from=construction /src/target/release/runeride-tool /src/cloud-service/target/release/runeride-envoi /src/cloud-service/target/release/runeride-worker /usr/local/bin/
ENV HOME=/tmp
ENTRYPOINT ["/usr/local/bin/runeride-envoi"]
