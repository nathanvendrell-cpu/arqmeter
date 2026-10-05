# ARQMETER

Un centre de pilotage macOS pour la consommation observée de Codex, Claude Code,
Gemini CLI et Ollama. Les sources restent séparées : un volume de tokens n’est
pas un quota, et un ancien journal n’est pas une session en cours.

## Version 1.0.8

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

L’accès aux compteurs de conversations ChatGPT ordinaires n’est pas implémenté.
La présence de Codex connecté ne donne pas ces compteurs. Le dépôt publie le
périmètre fonctionnel actuel, pas une extension ChatGPT déjà disponible.

## Validation de cette préversion

85 tests du moteur et les cinq autotests de présentation/cadran/lecture/archives/
quota passent dans l’environnement de développement. Le déplacement et le
maintien du HUD hors focus ont été contrôlés dans une exécution native de QA.
L’apparence sur tout fond de bureau et la validation visuelle humaine ne sont
pas déduites de ces tests. Aucune capture privée n’est publiée.
