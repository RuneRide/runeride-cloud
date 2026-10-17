# RuneRide Cloud

Service hébergé de RuneRide : stockage des rushs, montage et export GPU, sur AWS (eu-north-1).

- `rust/` : moteur et serveur, copiés depuis Bike360 (ancien nom ; dépôt `insta-build`) puis renommés : `render/` (GPU, demande CUDA), `core/`, `server/`, `cloud-service/` (espace de travail à part). `cargo check` dans `rust/` ne compile pas `render/`.
- `terraform/` : infrastructure AWS (`socle/`, `deploiement/` : copiés de l'essai Bike360 et renommés, à réécrire au lot 2 ; aucun état copié)
- Les rushs des utilisateurs sont stockés sur S3.
- Les comptes et la baseline gratuite vivent dans le dépôt `runeride`.

Plan : [docs/plan.md](docs/plan.md)
