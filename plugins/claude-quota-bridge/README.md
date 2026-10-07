# Pont quota Claude Code

Ce mod observe les événements officiels `session.measure` contenant un changement
de `rateLimits`. Il transmet uniquement les fenêtres 5 h et 7 jours au binaire
Arqmeter installé dans `$HOME/Applications/Arqmeter.app`.

Aucune requête modèle ou HTTP, aucun accès aux credentials, conversations ou
transcripts. Deux processus courts et bornés par changement de quota : vérifier
la capacité du binaire, puis importer les seules mesures reconnues. Les erreurs
ne bloquent pas la session Claude. Les quotas ne sont jamais estimés.

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
