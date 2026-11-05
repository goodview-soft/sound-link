# Sound Link

Partage audio en réseau local (Godot 4.7) : un host diffuse le son de son PC, les clients
(PC Linux ou téléphone Android) l'écoutent et peuvent renvoyer leur micro, qui arrive dans le
micro virtuel « Sound-Link-Micro » du host.

- Lancer depuis les sources : `./sound-link.sh`
- Téléchargements : voir les [releases](https://github.com/goodview-soft/sound-link/releases).
- Publier une version : `./release.sh 1.1.0 "notes"` — l'appli propose ensuite la mise à jour
  (téléchargement du `.pck` seul ; nouveau programme complet si la version de Godot change).
