# Pont quota Claude Code

Ce mod observe les événements officiels `session.measure` contenant des fenêtres
de quota valides. Le champ `changed` décrit les valeurs qui ont changé : ce n'est
pas la liste des champs disponibles. Les quotas restent donc lus lorsque seul
le contexte ou le coût a changé. Il transmet uniquement les fenêtres 5 h et 7 jours au binaire
Arqmeter installé dans `$HOME/Applications/Arqmeter.app`.

Aucune requête modèle ou HTTP, aucun accès aux credentials, conversations ou
transcripts. Deux processus courts et bornés par livraison : vérifier
la capacité du binaire, puis importer les seules mesures reconnues. Les erreurs
ne bloquent pas la session Claude. Les quotas ne sont jamais estimés.

Un changement de quota est transmis immédiatement. Deux relevés identiques dans
une même session sont regroupés pendant 60 secondes, pas ignorés indéfiniment.
Un nouvel événement réel est nécessaire pour renouveler un reçu : aucun timer
ne réécrit un ancien chiffre en lui attribuant une fausse fraîcheur serveur.

## Installer

Avec une version de Claude Code prenant en charge les Mods, et Arqmeter 1.0.19
construit puis installé dans le dossier Applications de votre utilisateur :

```sh
claude plugin marketplace add nathanvendrell-cpu/arqmeter
claude plugin install arqmeter-quota-bridge@arqmeter --scope user
```

Utiliser `/reload-plugins` dans une session déjà ouverte, ou ouvrir la prochaine
session normalement. Le pont fonctionne dans Claude Code et l'onglet Code de
Claude Desktop, pas dans son onglet Chat générique. Les modes safe/bare ou les
hooks désactivés empêchent son chargement. La status line existante est conservée.

Dans Arqmeter → Réglages → Claude Code, choisir **5 h**, **Semaine** ou **Les deux**.
Dans ce dernier cas, 5 h vient toujours en premier. Ce sont les pourcentages
restants, non les pourcentages utilisés.

La réception locale n'est pas une date serveur. Sans nouvel événement, Arqmeter
ne prétend pas à une mesure fraîche : après trois minutes, les derniers chiffres
restent accompagnés d'une horloge et de « Dernier relevé · non actualisé » dans
le détail. Chaque valeur est invalidée à son reset connu. Aucune activité Claude
n'est déclenchée pour renouveler les chiffres.

Ces événements portent les limites connues du moteur, issues de sa dernière
réponse API ; ils ne constituent pas un flux serveur continu. Une consultation
de `/usage` peut donc montrer un relevé plus récent sans produire un événement
`session.measure`. Le pont ne copie pas cette interface et ne transforme jamais
un ancien relevé en nouvelle mesure serveur.

## Vérifier et désactiver

```sh
claude plugin validate --strict --json plugins/claude-quota-bridge
claude plugin test plugins/claude-quota-bridge
claude plugin disable arqmeter-quota-bridge@arqmeter
```

Les tests utilisent uniquement des fixtures ; ils n'écrivent pas le cache réel.
La désactivation ne supprime ni historique ni préférences Arqmeter. Le contrôle
de capacité empêche d'exécuter un ancien binaire après rollback.

Contrat : [référence officielle des Mods](https://code.claude.com/docs/en/plugins/mods/reference).
