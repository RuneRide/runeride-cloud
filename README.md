# RuneRide Cloud

Service hébergé de RuneRide : stockage des rushs, montage et export GPU, sur AWS (eu-north-1).

- `rust/` : moteur et serveur, copiés depuis Bike360 (`insta-build`: `render/`, `core/`, `server/`, `cloud/service`)
- `terraform/` : infrastructure AWS
- Les comptes et la baseline gratuite vivent dans le dépôt `runeride`.

Plan : [docs/plan.md](docs/plan.md)
