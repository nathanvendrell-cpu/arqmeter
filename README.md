# ARQMETER

Un centre de pilotage macOS pour la consommation observée de Codex, Claude Code,
Gemini CLI et Ollama. Les sources restent séparées : un volume de tokens n’est
pas un quota, et un ancien journal n’est pas une session en cours.

## Version 1.0.12

La barre de menus réunit désormais les logos Claude et Codex, chacun avec son
pourcentage **restant**, dans un seul cadre. Les limites ne sont jamais additionnées.
L’infobulle indique la fenêtre, le reset et la provenance lorsqu’ils sont connus.
Les fenêtres, cadrans et vues détaillées existants ne sont pas recomposés.

L’onglet Quota présente les sources sélectionnées dans leur ordre enregistré.
Les réglages permettent de cocher plusieurs sources et de déplacer chacune avec
les flèches. Claude affiche indépendamment la session et la semaine lorsqu’elles
sont réellement connues ; la barre retient la fenêtre disponible la plus
contraignante. Gemini et Ollama montrent leurs mesures observées, pas un faux quota.

Les conseils restent des pistes à tester, sans économies promises. Un ratio
entrée/sortie élevé n’est plus une alerte de gaspillage : il explique aussi le
cache. Les comparaisons utilisent l’entrée par réponse, avec provider, modèle et
workspace connus et homogènes, plutôt que des sessions de longueurs différentes.
Aucune conversation n’est raccourcie, supprimée ou reroutée automatiquement.

- Fenêtre historique de 420 × 650 points, ouverte directement depuis le chiffre
  de la barre de menus ; un nouveau clic la masque ou la rouvre.
- Déplacement par l’en-tête. La position est conservée lors du masquage et de la
  réouverture dans la même exécution, pas garantie après un redémarrage.
- Verre clair et textes/repères foncés, indépendamment du mode sombre système.
  La fenêtre reste affichée hors focus et devient plus transparente ; le clic
  interne rétablit le fond plus couvrant. « Réduire la transparence » conserve
  un fond opaque clair et lisible.
- Trois cadrans : total, entrée hors cache et sortie. Moyennes en tokens/s sur
  1 min, 10 min, 1 h et 24 h ; volumes officiels du compte sur 7 j et 30 j.
- Dossiers, quota Codex, comparaisons, sessions, preuves et essais restent
  accessibles. Les mesures manquantes ne sont pas inventées.

Les événements Codex arrivent en fin de réponse : les cadrans ne représentent
pas un comptage token par token pendant la génération. Les journaux locaux sont
relus toutes les deux secondes pendant l’affichage, sans requête à un modèle.
La limite officielle Codex est actualisée séparément. Les tokens locaux ne se
convertissent pas en pourcentage de quota.

## Construire

Le projet utilise Swift Package Manager et les frameworks macOS, sans dépendance
Swift tierce. Utiliser un Xcode/SDK macOS 26 ou plus récent pour compiler les API
de verre natives ; la cible minimale déclarée est macOS 13, avec matériau de
repli avant macOS 26. La compatibilité avec les anciennes versions n’a pas été
recettée sur une machine distincte.

```sh
swift test
zsh scripts/build.sh
open build/Arqmeter.app
```

Le bundle distribué est une préversion **Apple Silicon (arm64)**, signée ad hoc,
non notarisée. Il ne constitue pas une distribution Mac App Store. Les fichiers
de sommes de contrôle accompagnent la release. Ne pas lancer plusieurs copies
de l’application simultanément.

## Données et limites

Les adaptateurs lisent les traces déjà présentes sur le Mac. Les historiques
sont locaux, dans le dossier Application Support d’Arqmeter. Aucun historique,
identifiant de compte, credential, capture de bureau ou journal utilisateur
n’est inclus dans ce dépôt. Les tests utilisent des exemples construits.
Voir [PRIVACY.md](PRIVACY.md).

### Limite Claude : liaison locale facultative

Claude Code peut fournir les champs officiels `rate_limits` à sa status line
pour un abonnement Pro/Max, après la première réponse API de la session.
Arqmeter ne lance aucune réponse pour obtenir ces données et ne lit ni cookies
ni credentials. Voir la [documentation officielle Claude Code](https://code.claude.com/docs/en/statusline).

Le fragment `Resources/claude-statusline-fragment.sh` peut être sourcé **après**
que votre commande de status line existante a lu stdin dans `input`. Il suppose
une installation dans `$HOME/Applications/Arqmeter.app`. Conserver votre commande
existante et la sauvegarder avant ajout ; le build n’altère pas vos réglages Claude.
Le fragment ne produit aucun affichage et vérifie la capacité du binaire avant
de l’appeler, pour rester inactif après un rollback vers une ancienne version.

Les fenêtres session et semaine restent indépendantes. La barre affiche la plus
contraignante parmi celles qui sont connues et valides, pas systématiquement la semaine.
Une fenêtre absente, expirée ou reçue depuis plus de trois minutes donne « — % »,
jamais 100 %. Le délai de réception ne prouve pas une nouvelle interrogation
du serveur : Claude Code peut réémettre un payload déjà reçu.
Une session cloud Claude ou l’interface web ne remplit pas cette liaison locale.
Le premier événement ordinaire ne suffit que si la version/session Claude Code
fournit effectivement ces champs ; Arqmeter ne remplace pas une donnée absente.

### Claude : lecteur facultatif de la page officielle (expérimental)

Dans les réglages d’Arqmeter, « Connecter Claude » ouvre la page officielle
https://claude.ai/settings/usage dans un navigateur WebKit dédié.
L’utilisateur effectue personnellement la connexion ; une connexion dans Claude
Desktop ou Chrome ne connecte pas automatiquement ce navigateur.
Arqmeter ne lit ni cookies, ni identifiants, ni codes de vérification.

Seuls les deux compteurs de quota reconnus sur cette page officielle sont
conservés. Après une première lecture réussie, la page est rechargée toutes les
60 secondes, sans appel modèle. Les erreurs entraînent un délai croissant et
les pages de connexion ne produisent aucune mesure. « Arrêter le suivi » arrête
le navigateur ; « Utiliser Claude Code » choisit explicitement la liaison locale.
Un choix web sans mesure fraîche reste « — % », sans repli silencieux vers un
autre compte Claude Code. L’heure de lecture n’est pas une fraîcheur serveur.

L’authentification et l’extraction d’une vraie page de compte connecté restent à
valider dans cette préversion. Les tests de DOM construits ne les remplacent pas.
Un parcours de connexion aboutissant hors de la page d’utilisation n’a pas encore
été recetté ; aucun quota fictif n’est utilisé pour le masquer.

L’accès aux compteurs de conversations ChatGPT ordinaires n’est pas implémenté.
La présence de Codex connecté ne donne pas ces compteurs. Le dépôt publie le
périmètre fonctionnel actuel, pas une extension ChatGPT déjà disponible.

## Validation de cette préversion

111 tests du moteur passent sur le candidat des sources et de la connexion.
Les neuf tests ciblés des conseils passent après leur correction, dont cinq
nouveaux cas (les autres preuves restent à leur portée). Sept autotests du
binaire et 18 contrôles de DOM construits passent.
Le nouveau cadre a été contrôlé par rendu AppKit hors écran, pas par une capture
de la barre de menus installée ; cette observation native reste à confirmer.
Le déplacement et le
maintien du HUD hors focus ont été contrôlés dans une exécution native de QA.
La sélection multiple et le changement d’ordre par flèches persistent après
redémarrage dans la recette native isolée. Le premier glisser-déposer des cartes
n’a pas modifié l’ordre : ce geste n’est pas déclaré validé.
L’apparence sur tout fond de bureau et la validation visuelle humaine ne sont
pas déduites de ces tests. Aucune capture privée n’est publiée.
