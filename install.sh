#!/bin/bash

# Définition des variables
LOG_DIR="logs"
LOG_FILE="logs/install.log"
LIBRARIES_FILE="template/libraries.txt" # Nom du fichier contenant les librairies
IMAGE_NAME="seatable/seatable-python-runner"
NEW_IMAGE_TAG="LIBS"
CONTAINER_NAME="ajout-libs"
CONFIG_FILE="python-pipeline.yml" # Chemin du fichier de configuration à modifier
ENV_FILE=".env"
STACK_NAME="seatable" # Nom du service stack

# Fonction pour écrire dans le fichier de log
log() {
    local message=$1
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $message" >> $LOG_FILE
}

# Fonction pour exécuter une commande et logger sa sortie
exec_log() {
    local command=$1
    echo "Commande exécutée: $command" >> $LOG_FILE
    eval $command 2>&1 | tee -a $LOG_FILE
    if [ $? -ne 0 ]; then
        echo "Erreur lors de l'exécution de la commande : $command" >> $LOG_FILE
        exit 1
    fi
}

# Fonction pour vérifier et créer le répertoire
check_and_create_directory() {
    if [ ! -d "$LOG_DIR" ]; then
        echo "Le répertoire $LOG_DIR n'existe pas. Création en cours..."
        mkdir -p "$LOG_DIR"
        if [ $? -eq 0 ]; then
            echo "Le répertoire $LOG_DIR a été créé avec succès."
        else
            echo "Erreur lors de la création du répertoire $LOG_DIR."
            exit 1
        fi
    fi
}


# Fonction d'installation de Seatable
install_seatable() {
    check_and_create_directory
    log "Vérification de la présence du répertoire logs..."

    cp template/seatable-server-template.yml seatable-server.yml
    cp template/python-pipeline-template.yml python-pipeline.yml
    
    export $(grep -v '^#' $ENV_FILE | xargs) && envsubst < template/seatable-server-template.yml > seatable-server.yml
    export $(grep -v '^#' $ENV_FILE | xargs) && envsubst < template/python-pipeline-template.yml > python-pipeline.yml

    sed -i "s/^SEATABLE_MYSQL_ROOT_PASSWORD=.*/SEATABLE_MYSQL_ROOT_PASSWORD='$(pwgen 40 1)'/" .env
    sed -i "s/^PYTHON_SCHEDULER_AUTH_TOKEN=.*/PYTHON_SCHEDULER_AUTH_TOKEN='$(pwgen 40 1)'/" .env
    sed -i "s/^SEATABLE_FAAS_AUTH_TOKEN=.*/SEATABLE_FAAS_AUTH_TOKEN='$(pwgen 40 1)'/" .env
    

    docker-compose up -d

    sleep 20

    echo "SEATABLE_FAAS_AUTH_TOKEN = '${SEATABLE_FAAS_AUTH_TOKEN}'" >> seatable-server/seatable/conf/dtable_web_settings.py
    echo "SEATABLE_FAAS_URL = '${SEATABLE_FAAS_URL}'" >> seatable-server/seatable/conf/dtable_web_settings.py

    sed -i "/\[REDIS\]/,/^$/s/^host = .*/host = ${REDIS_POD}/" seatable-server/seatable/conf/dtable-events.conf
    sed -i "/'LOCATION': /s/'LOCATION': .*,/'LOCATION': '${MEMCACHED_POD}',/" seatable-server/seatable/conf/dtable_web_settings.py

    sleep 10

    docker exec -d ${SEATABLE_POD} /shared/seatable/scripts/seatable.sh restart

    sleep 5

    log "Installation de Seatable terminée."
}

# Fonction d'installation de Python
install_python() {
    log "Vérification de la présence du répertoire logs..."
    check_and_create_directory

    # Vérification de l'existence du fichier des librairies
    if [ ! -f "$LIBRARIES_FILE" ]; then
        log "Le fichier $LIBRARIES_FILE n'existe pas. Le script va s'arrêter."
        exit 1
    fi

    # Lecture du fichier libraries.txt et stockage des librairies dans une variable
    LIBRARIES=$(cat $LIBRARIES_FILE | tr '\n' ' ')

    log "Téléchargement de l'image Docker..."
    exec_log "docker pull $IMAGE_NAME:latest"

    log "Création et démarrage du conteneur temporaire..."
    exec_log "docker run -d --name='$CONTAINER_NAME' $IMAGE_NAME custom"

    log "Installation des packages Python spécifiés dans $LIBRARIES_FILE dans le conteneur..."
    exec_log "docker exec -it $CONTAINER_NAME pip install $LIBRARIES"

    log "Création de la nouvelle image Docker avec le TAG $NEW_IMAGE_TAG"
    exec_log "docker commit -m 'add APPS' --change 'CMD null' $CONTAINER_NAME $IMAGE_NAME:$NEW_IMAGE_TAG"

    log "Mise à jour de la variable PYTHON_RUNNER_IMAGE dans le fichier de configuration"
    exec_log "sed -i 's|PYTHON_RUNNER_IMAGE=seatable/seatable-python-runner:latest|PYTHON_RUNNER_IMAGE=${IMAGE_NAME}:${NEW_IMAGE_TAG}|' $CONFIG_FILE"

    log "Démarrage du conteneur avec la nouvelle image"
    exec_log "docker-compose up -d"

    log "Nettoyage : arrêt et suppression du conteneur temporaire"
    exec_log "docker stop $CONTAINER_NAME && docker container rm $CONTAINER_NAME"

    log "Installation des librairies Python terminée!"
}

# Fonction de désinstallation
uninstall() {
    log "Désinstallation de Seatable et nettoyage..."
    docker-compose down -v 
    rm -R mariadb seatable-server logs
    rm seatable-server.yml
    rm python-pipeline.yml
}

# Fonction pour vérifier si la stack est déjà lancée
is_stack_running() {
    if [ "$(docker-compose ps | wc -l)" -gt 2 ]; then
        return 0
    else
        return 1
    fi
}

# Fonction pour remplacer les suffixes des variables dans le fichier .env
update_env_file() {
    local new_suffix="$1"
    sed -i "s|\(SEATABLE_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(MARIADB_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(MEMCACHED_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(REDIS_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(SEATABLE_NETWORKS=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(PYTHON_SCHEDULER_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(SEATABLE_FAAS_URL=.*://.*-\).*|\1${new_suffix}'|" $ENV_FILE
    sed -i "s|\(PYTHON_STARTER_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(PYTHON_RUNNER_POD=.*-\).*|\1${new_suffix}|" $ENV_FILE
    sed -i "s|\(PYTHON_NETWORKS=.*-\).*|\1${new_suffix}|" $ENV_FILE
}

# Main script
if is_stack_running; then
    :
else
    read -p "Souhaitez-vous créer/changer les paramètres (o/n) ? " change_params
    if [ "$change_params" = "o" ]; then
        # Demande des variables à l'utilisateur
        read -p "Entrez le domaine de Seatable : " SEATABLE_SERVER_HOSTNAME
        read -p "Entrez l'adresse email de l'administrateur : " SEATABLE_ADMIN_EMAIL
        read -s -p "Entrez le mot de passe de l'administrateur : " SEATABLE_ADMIN_PASSWORD
        echo
        read -p "Entrez le nouveau suffixe des conteneurs (par ex. 'beta') : " NEW_SUFFIX

        # Mise à jour du fichier .env
        sed -i "s|SEATABLE_SERVER_HOSTNAME=.*|SEATABLE_SERVER_HOSTNAME='${SEATABLE_SERVER_HOSTNAME}'|" $ENV_FILE
        sed -i "s|SEATABLE_ADMIN_EMAIL=.*|SEATABLE_ADMIN_EMAIL='${SEATABLE_ADMIN_EMAIL}'|" $ENV_FILE
        sed -i "s|SEATABLE_ADMIN_PASSWORD=.*|SEATABLE_ADMIN_PASSWORD='${SEATABLE_ADMIN_PASSWORD}'|" $ENV_FILE

        update_env_file "$NEW_SUFFIX"
    fi
fi

validate_uninstall() {
    read -p "Êtes-vous sûr de vouloir désinstaller Seatable ? Cette action est irréversible (o/n) : " confirm_uninstall
    if [ "$confirm_uninstall" != "o" ]; then
        echo "Désinstallation annulée."
        exit 0
    fi
}

echo "Que souhaitez-vous faire?"
echo "1) Installer Seatable"
echo "2) Installer les librairies Python supplémentaires"
echo "3) Installer Seatable ainsi que les librairies Python supplémentaires"
echo "4) Désinstaller Seatable"
echo "q) Quitter l'installation"
read -p "Entrez votre choix (1, 2, 3, 4 ou q pour quitter) : " choice

case $choice in
    1)
        install_seatable
        ;;
    2)
        install_python
        ;;
    3)
        install_seatable
        install_python
        ;;
    4)
        validate_uninstall
        uninstall
        ;;
    q)
        exit 0
        ;;
    *)
        echo "Choix invalide. Veuillez entrer 1, 2 ou 3."
        exit 1
        ;;
esac


echo "Script terminé. Vérifiez le fichier de log pour plus de détails : $LOG_FILE"
