# Plan RuneRide Cloud

Dépôt neuf. Le Rust est copié depuis Bike360 (dépôt `insta-build`, inchangé) ; l'infrastructure AWS est réécrite proprement.

## Lots

1. **Copie du Rust** : `render/`, `core/`, `server/`, `cloud/service` sous le nom RuneRide (crates, binaires, variables `BIKE360_*` → `RUNERIDE_*`).
2. **Terraform neuf** : ressources préfixées `runeride-`, état distinct de NomadRide et de `commun-pg` ; jamais de modification des ressources `nomadride-*`.
3. **Comptes** : plus de Cognito comme source ; vérifier les JWT RS256 émis par la baseline via son JWKS.
4. **Export GPU** : quota g4dn accordé à Stockholm (4 vCPU, 2026-10-17) ; un export à la fois ; essai à mener.
5. **Paiement et crédits** : Mollie, deux paliers (200 Go 25 €/an, 600 Go 49 €/an), crédits.

## Point d'attention

L'environnement d'essai Bike360 déjà déployé reste en place jusqu'à décision ; rien n'est détruit.
