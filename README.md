# ARQMETER

Un centre de pilotage macOS pour la consommation observée de Codex, Claude Code,
Gemini CLI et Ollama. Les sources restent séparées : les tokens ne sont pas un
quota, et un ancien journal n'est pas une session en cours.

## Sources 1.0.26

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
- Source principale mémorisée, affichage Codex + Claude et menu par clic droit :
  réglages, source principale, détails et quitter sans relance automatique.
- Projets regroupés avec choix de période : 1 min, 10 min, 1 h, 24 h, 7 j et 30 j.
  Le suivi Claude récent relit les journaux locaux disponibles de Claude Code,
  y compris l’onglet Code de Claude Desktop, sans fabriquer les mesures absentes.
- Gemini / Antigravity : quota du modèle reçu par le LanguageServer local,
  reset rapporté, fraîcheur explicite et largeur stable dans la barre de menus.
  Les transcriptions locales alimentent les compteurs par période et l’historique
  dédupliqué. Modèle, projet ou durée de fenêtre non fournis restent inconnus ;
  un reset seul ne devient jamais un quota nul. Aucun appel de génération.

### Analyse quotidienne dans la vue complète

« Voir les détails » → « Vue d’ensemble » ouvre d'abord la consommation de
la semaine civile, jour par jour. Les barres se consultent au survol ou au clic ;
les flèches du jour et « Valeurs par jour » donnent aussi accès aux chiffres exacts.
Le sélecteur Semaine/Mois et les flèches de période permettent de parcourir les
archives sans changer les filtres des sessions ou des conseils.

Choisir **Codex · compte** pour les volumes quotidiens officiels du compte
(jours UTC), ou une source **ce Mac** pour ses événements locaux (fuseau du Mac).
Ces populations ne sont jamais fusionnées. Les sources locales proposent la
mesure et le dossier observé : total traité, entrée hors cache, sortie, cache lu ;
Ollama expose sa durée locale lorsqu'elle est mesurée, pas des tokens inventés.
Le cache lu est déjà inclus dans l'entrée et ne s'ajoute pas au total traité.

Les jours manquants ne valent pas zéro ; les sommes incomplètes et la journée
en cours sont signalées. Aucun volume n'est converti en coût ou quota. Les cadrans,
comparaisons, sources et preuves restent accessibles à la demande, et le HUD
validé n'est pas recomposé. La lecture utilise les collecteurs et archives
existants : pas de nouvel appel modèle ni de minuterie de collecte supplémentaire.

### Claude : réception passive et dernier relevé explicite

Le [pont Claude Code Mods](plugins/claude-quota-bridge/README.md) reçoit les
mesures officielles de quota pendant l'activité normale de Claude Code,
y compris l'onglet Code de Claude Desktop. Il ne fait aucune requête modèle,
aucune requête HTTP et ne modifie pas votre status line.
Le pont 0.1.1 ne filtre plus les mesures sur le seul champ `changed=rateLimits` :
un nouvel événement réel contenant les mêmes pourcentages peut renouveler la
réception après 60 secondes, sans minuteur qui recyclerait un vieux relevé.

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
génération. Les journaux locaux Codex sont relus toutes les deux secondes pendant
l'affichage ; le suivi récent Claude est borné à une relecture toutes les quinze
secondes, sans appel modèle. Le quota officiel est actualisé séparément ;
les tokens locaux ne se convertissent pas en pourcentage de quota.

Les conseils distinguent contexte traité, cache lu et entrée hors cache avec
leur couverture. Une hausse dominée par le cache ne démontre pas un gaspillage.
Les comparaisons et essais manuels ne promettent aucun gain de coût, quota ou
qualité non mesuré. Aucun raccourcissement, effacement ou routage automatique.

L'accès aux compteurs des conversations ChatGPT ordinaires n'est pas implémenté.
Une connexion Codex ne fournit pas ces compteurs.

## Construire et vérifier

Swift Package Manager avec Sparkle 2.10.0 épinglé. Xcode/SDK macOS 26 ou plus
récent requis pour compiler les API de verre ; cible déclarée macOS 13 avec
matériau de repli. Les anciennes versions n'ont pas été recettées sur un autre Mac.

```sh
swift test
zsh scripts/build.sh
# Candidat temporaire : Products.noindex/Arqmeter-UpdaterCandidate.app
```

Le build embarque Sparkle 2.10.0 épinglé et vérifie les liens/signatures du bundle.
Il préserve un candidat déjà présent au lieu de le remplacer silencieusement.
« Rechercher les mises à jour… » est accessible par clic droit dans la barre.
Le flux HTTPS signé et la clé publique de publication ne sont pas configurés :
le candidat n’installe donc rien. Voir [le handoff updater](UPDATER-HANDOFF.md).
La [préparation de distribution et le contrat inter-apps](UPDATE-CONTRACT.md)
gardent séparés métadonnées, signatures, installation et preuve de relance.
L’application installée n’est pas remplacée par ces commandes ; ne pas lancer
une seconde instance pendant une recette. La production nécessite Developer ID,
notarisation, flux signé et version de build incrémentée.

Avant d'utiliser le pont, installer explicitement le bundle construit dans
$HOME/Applications/Arqmeter.app, après avoir arrêté votre seule instance Arqmeter
et vérifié un point de retour existant du binaire précédent. Ne pas multiplier
les copies d’application. Ne pas remplacer ni restaurer vos bases
de données. Ne pas lancer plusieurs copies simultanément.

Validation : tests moteur, autotests du binaire, tests du pont et signature ad hoc
sont distincts d'une observation native et d'une acceptation visuelle. Les tests
utilisent des exemples construits ; aucun reçu de compte réel n'est publié.
La suite 1.0.26 couvre 232 tests Swift, les tests du mod et les contrôles hors réseau
de présentation, cadrans, statistiques, comparaison, quota, barre et extracteur DOM.
La recette d'analyse vérifie aussi la sélection de source, mesure et dossier,
les réponses asynchrones dépassées et les états vides, sans requête de compte réel.

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
