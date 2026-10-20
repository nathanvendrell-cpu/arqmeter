# ARQMETER — support de mise à jour, 1.0.25

## État et limites

Le bundle embarque Sparkle **2.10.0 exact** (`Package.resolved`). Le clic droit
propose « Rechercher les mises à jour… » et « Inclure les préversions ».
Le support est intégré, mais **le service de publication n’est pas configuré** :
ni `SUFeedURL` ni `SUPublicEDKey` ne contiennent de valeur de substitution.
Une vérification explique cet état sans télécharger ni installer quoi que ce soit.

La publication des sources n’est pas une nouvelle release binaire. Le build
local reste signé ad hoc, sans notarisation ; il n’est pas présenté comme une
distribution Developer ID. Le premier passage depuis une version sans updater
nécessite une installation locale explicitement autorisée, pas une restauration
de préférences ou de bases de données.

## Politique

- Vérifications, téléchargement et installation automatiques désactivés par
  défaut ; aucune installation automatique proposée.
- Profil système désactivé, liste de clés de profil vide, aucun paramètre de
  suivi personnalisé. Aucune lecture de quotas, prompts ou historiques.
- HTTPS sans credentials ni paramètres de requête, flux signé et vérification
  de l’archive avant extraction obligatoires. Refus du fallback non signé.
- Nouvelle version de build uniquement, contraintes OS/hardware respectées,
  archives d’application uniquement, hôtes exacts autorisés.
- Canal stable sans élément de canal par défaut ; canal `prerelease` uniquement
  avec opt-in utilisateur mémorisé.
- Sparkle fournit l’interface standard : notes de version, progression, report,
  annulation, remplacement transactionnel et relance. Aucun installateur maison,
  migration de données ou réécriture du LaunchAgent ajouté.

## Construction et recette reproductible

```sh
swift test
zsh scripts/build.sh
Products.noindex/Arqmeter-UpdaterCandidate.app/Contents/MacOS/Arqmeter --updater-self-test
```

Le produit temporaire est placé sous `Products.noindex`. Un produit préexistant
est refusé, jamais supprimé silencieusement. Le packager préserve les symlinks
internes et permissions du framework, vérifie leur portée, signe le candidat ad
hoc et contrôle la signature profonde. Il ne lance ni n’installe l’application,
ne retire pas la quarantaine et ne change aucune protection macOS.

Les tests de politique couvrent configuration, HTTPS, signature, version, canal,
compatibilité et hôtes. Le test natif du menu/comparateur ne démarre ni collecte,
ni vérification réseau, ni installation. Les tests CryptoKit et le script
`scripts/test-updater-signatures.swift` utilisent des fixtures synthétiques :
signature valide acceptée, contenu altéré et mauvaise clé refusés. Le script
attend le chemin de l’outil officiel `sign_update`, utilise une graine éphémère
dans un répertoire privé, jamais le Keychain, puis nettoie ses fichiers/enfants.

Ces tests ne prouvent pas une mise à jour réelle ni une acceptation visuelle.
La recette complète de l’interface Sparkle, l’annulation, les interruptions,
la récupération et la relance avec le LaunchAgent restent à exécuter sur des
applications jetables signées avant de mettre en service le flux distant.

## Préparation d’une distribution distante

1. Configurer un appcast HTTPS détenu par l’éditeur dans `SUFeedURL`, la clé
   Ed25519 publique dans `SUPublicEDKey` et les hôtes d’archives exacts dans
   `ARQUpdateDownloadHosts`. Conserver la clé privée hors dépôt, bundle et logs.
2. Incrémenter le build, signer avec Developer ID les composants requis, notariser
   le bundle et contrôler l’archive finale et son architecture.
3. Produire le flux et les signatures avec les outils officiels depuis cette
   archive exacte ; ne pas modifier le contenu signé ensuite.
4. Tester versions/canaux, signatures invalides, interruptions, annulation,
   fallback complet, restauration et relance avant publication autorisée.

Les deltas sont facultatifs et doivent provenir des versions signées exactes ;
toujours conserver un téléchargement complet signé de repli. Aucun delta ni
flux de production n’est fourni ici. Ne pas créer un troisième point de retour.
Ce support est macOS uniquement et ne modifie pas la contribution Windows isolée.

Références : [Sparkle](https://sparkle-project.org/documentation/),
[intégration](https://sparkle-project.org/documentation/programmatic-setup/),
[deltas](https://sparkle-project.github.io/documentation/delta-updates/).
