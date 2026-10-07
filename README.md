# ARQMETER

Un centre de pilotage macOS pour la consommation observée de Codex, Claude Code,
Gemini CLI et Ollama. Les sources restent séparées : les tokens ne sont pas un
quota, et un ancien journal n'est pas une session en cours.

## Sources 1.0.19 — préversion

- Fenêtre historique de 420 × 650 points, ouverte directement depuis la barre
  de menus. Un nouveau clic la masque ou la rouvre ; déplacement par l'en-tête.
- Présentation en verre clair, cadrans et navigation existants conservés. Fond
  plus transparent hors focus, repli opaque avec « Réduire la transparence ».
- Cadrans de consommation : total, entrée hors cache, sortie. Moyennes en
  tokens/s sur 1 min, 10 min, 1 h et 24 h ; volumes officiels Codex sur 7 j et 30 j.
- Dossiers/projets, quotas, comparaisons, sessions, preuves et essais manuels
  accessibles. Aucune mesure manquante n'est inventée.
- Quotas Codex et Claude côte à côte, jamais additionnés. Pour Claude : choix
  mémorisé **5 h**, **Semaine** ou **Les deux**, avec 5 h en premier.

### Claude : réception passive et dernier relevé explicite

Le [pont Claude Code Mods](plugins/claude-quota-bridge/README.md) reçoit les
changements officiels de quota pendant l'activité normale de Claude Code,
y compris l'onglet Code de Claude Desktop. Il ne fait aucune requête modèle,
aucune requête HTTP et ne modifie pas votre status line.

Les chiffres de la barre sont les pourcentages **restants**. Après trois minutes
sans nouvelle réception, ils restent visibles avec une horloge : **dernier relevé,
non actualisé**, pas une mesure certifiée en temps réel. L'infobulle et le détail
indiquent l'heure et les resets. Au reset connu, seule la fenêtre concernée devient
indisponible jusqu'au prochain relevé ; aucun 100 % n'est fabriqué.

Le pont n'est pas un polling autonome lorsque Claude est fermé ou silencieux.
La date de réception locale n'est pas un timestamp de mesure serveur. Une lecture
de secours utilise la connexion existante de la CLI officielle, sans génération,
avec délais, backoff persistant et nettoyage des processus. Une réponse absente ou
nulle ne renouvelle pas un ancien relevé. L'ellipse est réservée à une lecture
effectivement en cours. Les anciens lecteurs Web/Desktop restent dans le code
pour les tests et archives ; ils ne sont plus proposés comme parcours quotidien.

Le fragment facultatif Resources/claude-statusline-fragment.sh reste compatible
avec une status line existante qui expose les champs officiels rate_limits.
Le build ne modifie pas vos réglages Claude. Un guard de capacité préserve le
rollback vers un ancien binaire.

### Interpréter les mesures

Codex rapporte les tokens en fin de réponse, pas token par token pendant la
génération. Les journaux locaux sont relus toutes les deux secondes pendant
l'affichage, sans appel modèle. Le quota officiel est actualisé séparément ;
les tokens locaux ne se convertissent pas en pourcentage de quota.

Les conseils distinguent contexte traité, cache lu et entrée hors cache avec
leur couverture. Une hausse dominée par le cache ne démontre pas un gaspillage.
Les comparaisons et essais manuels ne promettent aucun gain de coût, quota ou
qualité non mesuré. Aucun raccourcissement, effacement ou routage automatique.

L'accès aux compteurs des conversations ChatGPT ordinaires n'est pas implémenté.
Une connexion Codex ne fournit pas ces compteurs.

## Construire et vérifier

Swift Package Manager, sans dépendance Swift tierce. Xcode/SDK macOS 26 ou plus
récent requis pour compiler les API de verre ; cible déclarée macOS 13 avec
matériau de repli. Les anciennes versions n'ont pas été recettées sur un autre Mac.

```sh
swift test
zsh scripts/build.sh
open build/Arqmeter.app
```

Avant d'utiliser le pont, installer le bundle construit dans
$HOME/Applications/Arqmeter.app, après avoir arrêté votre seule instance Arqmeter
et conservé une copie du binaire précédent. Ne pas remplacer ni restaurer vos bases
de données. Ne pas lancer plusieurs copies simultanément.

Validation : tests moteur, autotests du binaire, tests du pont et signature ad hoc
sont distincts d'une observation native et d'une acceptation visuelle. Les tests
utilisent des exemples construits ; aucun reçu de compte réel n'est publié.
La passe 1.0.19 couvre 184 tests Swift, 7 tests du mod et les contrôles hors réseau
de présentation, cadrans, statistiques, comparaison, quota, barre et extracteur DOM.

La distribution précédente Apple Silicon est signée ad hoc, non notarisée.
RELEASE.json et SHA256SUMS décrivent cette distribution ancienne, **pas** le
build actuel des sources. Cette mise à jour du dépôt ne crée pas une nouvelle
release binaire ni une distribution Mac App Store.

## Confidentialité

Les historiques, modèles, workspaces, timestamps et provenance restent sur votre
Mac. Aucun prompt/réponse n'est stocké dans la base d'événements normalisés.
Ce dépôt ne contient ni données personnelles de quota, bases SQLite, secrets,
réglages utilisateur, logs, captures privées, sauvegardes ni binaires locaux.
Voir [PRIVACY.md](PRIVACY.md). Le contrôle de publication est ciblé ; il ne
constitue pas un audit de sécurité exhaustif.
