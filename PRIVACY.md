# Données et publication

## Sur votre Mac

Arqmeter lit les journaux et métadonnées locaux des outils détectés et les limites
Codex via son outil officiel lorsqu'elles sont accessibles. Aucun modèle n'est
exécuté pour produire les statistiques.

Les événements normalisés (timestamps, workspace/projet, modèle, métriques et
provenance) restent dans SQLite local. Les prompts et réponses ne sont pas
conservés dans cette base. Les analyses et essais manuels restent locaux ; aucune
économie non mesurée n'est promise.

## Pont Claude Code facultatif

Le mod observe uniquement session.measure lorsque rateLimits change. Il projette
les pourcentages utilisés et resets des deux fenêtres officielles 5 h/semaine,
et ignore contexte, coût, limites de dépenses et champs inconnus. Il ne lit ni
credentials, cookies, identités de compte, transcripts, session IDs ou prompts.
Il ne lance ni HTTP, génération, compaction, timer ni service de polling.

Le contrôle de capacité et l'import sont deux processus courts, avec timeout.
Le binaire écrit atomiquement claude-quota.json en 0600 : valeurs, resets, heure
de réception, version CLI assainie éventuelle et digest de déduplication. Le reçu
du mod utilise un identifiant de transport basé sur l'heure, non une session
utilisateur. Son store privé ne contient que la dernière livraison et provenance.
La status line déjà configurée n'est pas remplacée.

La fraîcheur serveur n'est pas fournie. Une réception silencieuse reste un dernier
relevé signalé comme non actualisé ; son timestamp n'est jamais renouvelé par la
lecture du cache. Chaque fenêtre expire à son reset connu. Aucun quota n'est estimé.

La liaison status line et la lecture de secours officielle restent disponibles.
Le lecteur de secours utilise la connexion gérée par Claude Code, refuse les
réponses nulles, ne lit pas de credentials et ne lance pas de réponse modèle.
Les erreurs entraînent un backoff persistant. Ses diagnostics stockent seulement
les états opérationnels bornés, pas les messages, terminaux bruts ou identités.

Les anciens chemins expérimentaux Web/Desktop sont conservés dans les sources
et tests, mais ne sont pas démarrés ni proposés par le parcours courant. Leurs
anciens caches locaux et historiques ne sont ni effacés ni publiés.

## Dans ce dépôt

Liste d'autorisation des fichiers : sources, tests à fixtures, ressources de build,
mod portable et documentation publique. Exclus : historiques personnels, quota
réel, bases SQLite, authentifications, réglages du Mac, logs, backups, archives
internes et captures du bureau. Les binaires ne sont pas ajoutés au Git.

Les anciens fichiers de distribution décrivent uniquement la release à laquelle
ils se rapportent. Mettre à jour les sources ne publie pas automatiquement un
nouveau bundle et n'inclut pas les données locales.

Le contrôle de publication cherche les credentials reconnaissables, chemins et
identifiants privés, ainsi que les fichiers interdits. Ce n'est pas une garantie
d'absence de toute vulnérabilité ni un audit de sécurité exhaustif.

Les logos Claude et OpenAI/Codex identifient les sources sans affiliation ou
endorsement ; les tracés viennent des favicons officiels.
