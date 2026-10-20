# ARQMETER — support de mise à jour, 1.0.26

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

Le [contrat commun](UPDATE-CONTRACT.md) et le préparateur
`scripts/prepare-sparkle-release.mjs` sont disponibles sans changer le moteur
installé. Ils ne créent pas de credential, ne publient ni n’installent rien.
Le contrat est une proposition à intégrer par les propriétaires AUTORENDER/BRAIN,
pas une intégration runtime déjà effectuée.

Recette de préparation : **16 tests Node réussis**, dont génération d’un vrai
appcast signé, archive jetable signée et manifeste JSON à signature détachée avec
les outils officiels épinglés ; altérations et mauvaise clé refusées. Les tests
couvrent aussi états, canaux, compatibilité, absence de signature Developer ID,
sortie déjà présente, parent symlinké et arrêt des processus/enfants sur timeout.
Fixtures, clés éphémères et caches d’extraction propres aux tests nettoyés.
Le signataire peut être fourni par fichier privé externe ou par compte Keychain
explicitement nommé, sans export de clé ; le préparateur ne crée aucun credential.

Sur le Mac de préparation, aucun Developer ID valide n’est disponible ; le
bundle installé ne contient ni feed ni clé publique, et le dépôt n’a pas de
secret/variable de publication configuré. Cela ne prouve pas l’absence d’une clé
privée conservée ailleurs par son propriétaire. Le préparateur refuse l’app
installée avec `configurationMissing`, sans sortie et sans installation.
La préparation d’une release ne modifie ni le bundle installé ni son service.

Contrôle Xcode du 20 octobre : compte connecté, seule une Personal Team est
proposée et aucun certificat n’est présent ; le menu ne propose qu’Apple
Development. Developer ID et notarisation restent bloqués avant activation
de l’adhésion appropriée. Aucun contrat ni paiement accepté automatiquement.
L’inscription a été ouverte jusqu’à la fiche de coordonnées. Les étapes
engageantes et payantes restent en attente d’un nouvel accord explicite ; aucun
paiement n’a été lancé par cette intervention. Les préparatifs gratuits, les
tests et l’installation locale ne dépendent pas de cette adhésion.

**Dépendance propriétaire précise** : mettre à disposition une identité Developer
ID/notarisation utilisable et le signataire Ed25519 approuvé (référence sécurisée,
jamais une clé collée dans un chat), avec sa clé publique et l’URL de feed retenue.
L’hébergement peut réutiliser le GitHub existant, sans nouveau compte. Aucune
création de credential ni publication de flux/binaire de test n’a été effectuée.
Ensuite, réserver une recette UI contrôlée avec le propriétaire : aucune preuve
de mise à jour Sparkle installée/reprise/rollback n’est encore revendiquée.

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
