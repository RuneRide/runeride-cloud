//! Emplacements des données (même arborescence que la version Python). Chaque dossier peut être
//! placé ailleurs par une variable d'environnement : en service hébergé, les données du client
//! sont sur un stockage monté, les caches et les exports sur le disque local de la machine.
use std::path::PathBuf;

/// Dossier donné par la variable `var` (ignorée si elle est vide), sinon celui par défaut.
fn dir(var: &str, default: impl FnOnce() -> PathBuf) -> PathBuf {
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(default)
}

/// Racine du projet : $RUNERIDE_ROOT, sinon le dossier du dépôt compilé.
pub fn root() -> PathBuf {
    dir("RUNERIDE_ROOT", || PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/..")))
}

/// Données à conserver (sélections, projet, réglages, traces GPS) : $RUNERIDE_DATA, sinon <racine>/data.
pub fn data() -> PathBuf {
    dir("RUNERIDE_DATA", || root().join("data"))
}

/// Résultats recalculables (analyses, vignettes, tuiles) : $RUNERIDE_CACHE, sinon <données>/cache.
pub fn cache() -> PathBuf {
    dir("RUNERIDE_CACHE", || data().join("cache"))
}

/// Vidéos exportées et leurs morceaux intermédiaires : $RUNERIDE_EXPORTS, sinon <racine>/exports.
pub fn exports() -> PathBuf {
    dir("RUNERIDE_EXPORTS", || root().join("exports"))
}

/// Mode hébergé ($RUNERIDE_CLOUD=1) : le serveur ne lit que le dossier de rushs qu'on lui donne et
/// n'explore ni le disque ni les cartes SD de sa machine.
pub fn cloud() -> bool {
    std::env::var("RUNERIDE_CLOUD").is_ok_and(|v| v == "1")
}
