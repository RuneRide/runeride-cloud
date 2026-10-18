# Tuiles (PMTiles) sur S3 + CloudFront

Remplace l'hébergement du fichier sur o2switch. Coût attendu : voir le forfait CloudFront Free (1 M de requêtes,
100 Go de transfert, 5 Go de crédit S3 par mois, sans dépassement facturé).

## Ordre d'application (chaque étape demande un accord explicite)

1. `terraform init && terraform plan`
2. `terraform apply -target=aws_acm_certificate.tuiles`, puis créer chez o2switch le CNAME de `validation_certificat`
   (DNS du domaine hors AWS), attendre l'émission.
3. `terraform apply`, puis créer le CNAME `tuiles` vers la sortie `cloudfront`.
4. Envoyer le fichier : `aws s3 cp aura-paca-bourgogne.pmtiles s3://<bucket>/ --content-type application/vnd.pmtiles`
5. Souscrire le forfait Free dans la console CloudFront (distribution → gérer le forfait). Le forfait impose un WAF
   associé et une distribution standard ; à vérifier au moment de la souscription (non géré ici).

## Points à vérifier avant production

- Requêtes Range sur un objet de 2,4 Go via CloudFront + OAC (tester avec `curl -H 'Range: bytes=0-16383'`).
- Un CNAME (au lieu d'un ALIAS Route 53) ne profite pas de l'allocation DNS du forfait : sans objet ici, la zone reste chez o2switch.
