#!/bin/bash

# Arrêter le script en cas d'erreur
set -e

echo "Création de l'arborescence exacte du projet Ansible..."

# Création de l'arborescence demandée
mkdir -p ansible_project/group_vars
mkdir -p ansible_project/roles/security_dns/tasks
mkdir -p ansible_project/roles/security_dns/templates
mkdir -p ansible_project/roles/security_dns/handlers
mkdir -p ansible_project/roles/admin_users/tasks

cd ansible_project

echo "1. Création de ansible.cfg..."
cat << 'EOF' > ansible.cfg
[defaults]
inventory = inventory.ini
roles_path = roles
remote_user = ansible
host_key_checking = False
EOF

echo "2. Création de inventory.ini..."
cat << 'EOF' > inventory.ini
[target_hosts]
server1 ansible_host=192.168.1.10
EOF

echo "3. Création de playbook.yml..."
cat << 'EOF' > playbook.yml
---
- name: "Playbook principal - TP Module 09"
  hosts: target_hosts
  become: true
  roles:
    - role: security_dns
    - role: admin_users
EOF

echo "4. Création de group_vars/all.yml..."
cat << 'EOF' > group_vars/all.yml
---
# Paramètres pour le rôle security_dns
dns_forwarders:
  - "{{ ansible_default_ipv4.gateway }}"

# Paramètres pour le rôle admin_users
password_length: 16
admin_username: "sysadmin"
EOF

echo "5. Création de group_vars/vault.yml..."
cat << 'EOF' > group_vars/vault.yml
---
admin_ssh_public_key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG... votre_cle_publique_exemple"
EOF

echo "6. Création de roles/security_dns/tasks/main.yml..."
cat << 'EOF' > roles/security_dns/tasks/main.yml
---
- name: "Installer le serveur DNS BIND"
  ansible.builtin.apt:
    name:
      - bind9
      - bind9utils
    state: present
  when: ansible_os_family == "Debian"

- name: "Sécurisation de la configuration SSH (Désactivation Root)"
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PermitRootLogin'
    line: 'PermitRootLogin no'
    state: present
  notify: Redémarrer SSH

- name: "Configuration de BIND avec bloc de contrôle et rollback"
  block:
    - name: "Sauvegarde de l'ancienne configuration BIND"
      ansible.builtin.copy:
        src: /etc/bind/named.conf.options
        dest: /etc/bind/named.conf.options.bak
        remote_src: true
        force: true

    - name: "Déploiement du nouveau template BIND"
      ansible.builtin.template:
        src: named.conf.options.j2
        dest: /etc/bind/named.conf.options
        owner: bind
        group: bind
        mode: '0644'

    - name: "Contrôle de la syntaxe du fichier BIND"
      ansible.builtin.command: named-checkconf /etc/bind/named.conf.options
      changed_when: false

  rescue:
    - name: "Échec détecté : Restauration de l'ancienne configuration (Rollback)"
      ansible.builtin.copy:
        src: /etc/bind/named.conf.options.bak
        dest: /etc/bind/named.conf.options
        remote_src: true

    - name: "Arrêt du playbook suite à l'échec BIND"
      ansible.builtin.fail:
        msg: "Erreur de configuration BIND détectée. Rollback effectué."

  always:
    - name: "Redémarrage du service BIND"
      ansible.builtin.service:
        name: bind9
        state: restarted
        enabled: true
EOF

echo "7. Création de roles/security_dns/templates/named.conf.options.j2..."
cat << 'EOF' > roles/security_dns/templates/named.conf.options.j2
options {
    directory "/var/cache/bind";

    // Désactivation de DNSSEC et activation de la redirection unique
    dnssec-validation no;
    forward only;

    // Redirection vers le DNS configuré sur l'hôte cible
    forwarders {
        {% for fw in dns_forwarders %}
        {{ fw }};
        {% endfor %}
    };

    auth-nxdomain no;
    listen-on { any; };
};
EOF

echo "8. Création de roles/security_dns/handlers/main.yml..."
cat << 'EOF' > roles/security_dns/handlers/main.yml
---
- name: Redémarrer SSH
  ansible.builtin.service:
    name: ssh
    state: restarted
EOF

echo "9. Création de roles/admin_users/tasks/main.yml..."
cat << 'EOF' > roles/admin_users/tasks/main.yml
---
- name: "Générer un mot de passe aléatoire sécurisé"
  ansible.builtin.set_fact:
    generated_admin_password: "{{ lookup('ansible.builtin.password', '/dev/null length=' ~ password_length ~ ' chars=ascii_letters,digits,hexdigest') }}"
  no_log: true

- name: "Créer le groupe d'administration"
  ansible.builtin.group:
    name: admin
    state: present

- name: "Créer l'utilisateur d'administration"
  ansible.builtin.user:
    name: "{{ admin_username }}"
    group: admin
    shell: /bin/bash
    password: "{{ generated_admin_password | password_hash('sha512') }}"
    create_home: true
    state: present

- name: "Donner les droits sudoers avec mot de passe"
  ansible.builtin.copy:
    dest: "/etc/sudoers.d/{{ admin_username }}"
    content: "{{ admin_username }} ALL=(ALL:ALL) ALL"
    mode: '0440'
    validate: 'visudo -cf %s'

- name: "Créer le répertoire .ssh pour l'utilisateur"
  ansible.builtin.file:
    path: "/home/{{ admin_username }}/.ssh"
    state: directory
    owner: "{{ admin_username }}"
    group: admin
    mode: '0700'

- name: "Pousser la clé SSH publique préalablement vaultée"
  ansible.posix.authorized_key:
    user: "{{ admin_username }}"
    state: present
    key: "{{ admin_ssh_public_key }}"

- name: "Afficher le mot de passe généré à la fin de l'exécution"
  ansible.builtin.debug:
    msg: "UTILISATEUR CRÉÉ -> Nom: {{ admin_username }} | Mot de passe: {{ generated_admin_password }}"
EOF

echo "Projet généré avec succès dans le dossier './ansible_project' !"
