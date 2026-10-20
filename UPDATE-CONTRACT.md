# Contrat minimal de mise à jour — v1

Identifiant : `7agency.app-update.v1`. Proposition de contrat commun pour
ARQMETER, AUTORENDER et le catalogue/launcher BRAIN, sans framework obligatoire.
Le validateur de référence est `scripts/update-contract.mjs` ; il n’installe rien.
Les adaptateurs BRAIN et AUTORENDER ne sont pas implémentés par ce document.

## 1. Métadonnées publiques d’une release

| Champ | Type / règle |
|---|---|
| `schemaVersion` | Exactement `7agency.app-update.v1` |
| `productID` | Identité stable en reverse DNS, propre à l’app |
| `version` | Version affichable, chaîne non vide bornée |
| `build` | Identifiant de build ; ordre décidé par l’adaptateur natif |
| `platform` | `macos`, `windows`, `linux` |
| `architecture` | `arm64`, `x86_64`, `universal2` (ce dernier : macOS seulement) |
| `channel` | `stable`, ou `prerelease` sur opt-in explicite |
| `artifact.url` | URL HTTPS exacte autorisée par la configuration de l’éditeur |
| `artifact.sizeBytes` | Taille exacte entière positive, sans arrondi |
| `artifact.sha256` | SHA256 hexadécimal minuscule de l’archive finale |
| `artifact.signature.algorithm` | `ed25519` pour ce contrat v1 |
| `artifact.signature.value` | Signature base64 canonique de 64 octets |
| `artifact.signature.publicKeyID` | SHA256 de la clé publique brute de 32 octets |

Tous les champs sont obligatoires ; les champs inconnus sont refusés en v1.
Ni clé privée, credential, chemin utilisateur, prompt, quota, historique ou
erreur brute ne figurent dans ces métadonnées. Le fingerprint n’est pas une clé
de confiance : la clé publique approuvée est fournie hors de ces métadonnées.

**Un JSON valide n’est pas authentifié.** Les métadonnées doivent être liées à
un flux signé ou manifeste signé validé par la racine de confiance de l’app.
Le préparateur produit aussi `release.json.ed25519`, signature détachée des octets
exacts de `release.json`, pour les adaptateurs non-Sparkle. Vérifier la signature
avec la clé publique préapprouvée avant de parser/afficher ces métadonnées ; ne pas
reformater le JSON signé. La signature du JSON et celle de l’archive sont distinctes.
Le hash seul ne prouve pas l’identité de l’éditeur. Une archive valide n’autorise
ni un autre produit, ni un downgrade, ni un canal non demandé.

## 2. État d’une opération

Champs exacts : `schemaVersion`, `productID`, `operationID` (UUID), `updatedAt`
(ISO8601 UTC canonique), `state`, `installedBuild`, `target` (release ci-dessus ou
null), `downloadedBytes` (entier exact ou null), `errorCode` (code ou null),
`retryable` (booléen). Horodatage d’observation locale, jamais prétendu serveur.

| État | Présentation utilisateur / preuve exigée |
|---|---|
| `unconfigured` | Mises à jour non configurées, sans réseau ni faux « à jour » |
| `idle` / `checking` | Au repos / recherche effectivement en cours |
| `upToDate` | Recherche authentifiée terminée, aucune version éligible |
| `available` | Version compatible et plus récente effectivement proposée |
| `downloading` | Téléchargement en cours, octets exacts si connus |
| `readyToInstall` | Archive et identité vérifiées, confirmation encore requise |
| `installing` / `relaunching` | Opérations réelles, pas encore une réussite |
| `succeeded` | Version cible relue dans l’app relancée, données/préférences préservées vérifiées |
| `cancelled` | Annulation demandée, ancienne app et données conservées |
| `blocked` / `failed` | Dépendance ou erreur explicite, état de l’app actuelle préservé |

Une cible est requise de `available` à `succeeded`. En réussite,
`installedBuild == target.build` ; ce contrôle de cohérence ne remplace pas la
preuve runtime. BRAIN ne déduit jamais `succeeded` d’un download, d’un HTTP 200,
d’un hash, d’un build ou d’une simple demande de relance.

Codes : `configurationMissing`, `signingUnavailable`, `network`, `invalidFeed`,
`invalidArchive`, `incompatible`, `notWritable`, `userCancelled`, `installFailed`,
`relaunchUnverified`, `unknown`. Message français présenté localement, sans
remonter la sortie brute d’un outil ou un credential. `retryable` ne relance rien.

## 3. Sécurité commune, mécanisme propre à chaque app

Commun : HTTPS, racine de confiance extérieure aux métadonnées, signatures et
hash/longueur vérifiés sur l’archive exacte avant extraction, produit/plateforme/
architecture/version/canal contrôlés. Aucun appel modèle ou profilage. Une
annulation/erreur conserve les données ; aucune restauration automatique d’une
ancienne base. Maximum deux points de retour utiles ; réutiliser l’existant,
ne jamais purger une sauvegarde sans confirmation humaine.

- **ARQMETER macOS** : Sparkle 2.10.0, appcast signé + archive Ed25519,
  `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, validation native de
  version/compatibilité, Developer ID/notarisation pour la distribution. L’adapter
  reste propriétaire de son UI native, remplacement et récupération.
- **AUTORENDER** : le propriétaire choisit l’adaptateur compatible avec sa chaîne
  de distribution/signature ; aucun changement de framework prescrit ici.
- **BRAIN** : catalogue/bootstrap initial et présentation des états ; pas un
  second installateur en concurrence avec celui de l’app. Aucun rechargement ou
  écrasement d’un profil BRAIN pour mettre à jour un binaire.

Si une plateforme utilise une autre signature d’archive, étendre/versionner le
contrat explicitement ; ne pas déclarer Ed25519 « verified » par défaut. Signature
d’archive et signature/notarisation de code sont deux contrôles distincts.

## 4. Préparation ARQMETER sans publication implicite

`scripts/prepare-sparkle-release.mjs` attend explicitement : `--app`, `--tools`,
`--key-file`, `--output`, `--download-prefix`, `--installed-build`, et facultativement
`--channel stable|prerelease`. Node et les outils Xcode/macOS sont requis.

L’app doit déjà contenir le vrai feed, la vraie clé publique et les hôtes admis,
être signée Developer ID et notarisée/stapled. La clé privée existante est fournie
par un fichier externe au projet et au bundle, propriétaire courant, permissions
privées ; jamais un argument contenant le secret, un fallback Keychain ou une
clé créée par le script. Outils officiels 2.10.0 épinglés par hash.

Sortie neuve uniquement sous `Products.noindex` : ZIP conservant les symlinks,
appcast généré/signé avec `generate_appcast`, manifeste `release.json` et sa
signature détachée `release.json.ed25519`, reçu
`preparation.json`. L’archive est aussi extraite et sa signature/notarisation
recontrôlée. Le feed est revérifié avec l’outil officiel et ses champs sont reliés
à l’archive exacte. Deltas désactivés dans cette première préparation.
**Aucun upload, compte, credential, installation, réécriture de plist ou de
LaunchAgent.** Un résultat `prepared` ne vaut pas publication/installation.

Pour un hébergement existant sans nouveau compte, une possibilité à approuver
est le dépôt GitHub de l’éditeur : flux XML signé versionné et archives de release
avec URLs HTTPS stables. Aucune URL de test n’est installée comme flux officiel.
Le dernier binaire installé sans feed/clé nécessite encore un bootstrap de
confiance une fois ces éléments fournis ; ensuite Sparkle réalise les mises à jour
dans l’UI. Ce bootstrap ne réinstalle pas les réglages ni les historiques.

## 5. Tests et gates

```sh
node --test scripts/test-update-contract.mjs
ARQ_SPARKLE_TOOLS=Products.noindex/UpdaterTools/bin node --test scripts/test-update-contract.mjs
```

Tests : forme stricte, produits distincts, transport/hôtes, canaux, version native
et compatibilité, métadonnées non authentifiées, hash/signature/clé altérés,
états et faux succès, configuration absente, process borné et récolté. Le test
SDK opt-in génère un **vrai appcast signé sur une archive d’app jetable**, puis
refuse une altération. Clé de fixture éphémère et fichiers supprimés en finally.
Ce n’est pas une mise à jour installée, et ne remplace pas la recette suivante :

1. Disponibilité UI et « Plus tard » ; annulation avant/après téléchargement.
2. Réseau interrompu, mauvaise signature/clé, mauvais produit/canal/architecture,
   version inférieure, destination non inscriptible : ancienne app préservée.
3. Installation contrôlée par le mécanisme natif ; relance de la bonne version,
   instance unique et même chemin de service. Aucune UI concurrente.
4. Préférences et historique de fixture relus après relance, puis contrôles
   proportionnés sur l’installation autorisée, sans publier les données.
5. Récupération sur échec et retour arrière via point validé, avec consentement
   pour l’opération réelle ; pas de downgrade automatique ni de restauration DB.

La recette installée n’est pas acquise tant que certificat/clé/flux et créneau UI
ne permettent pas ces observations. État actuel : voir `UPDATER-HANDOFF.md`.
