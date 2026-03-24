#!/bin/bash
set -e

USERS_DIR="/var/lib/btcentral/users"
SERVERS_FILE="/var/lib/btcentral/servers.txt"
CENTRAL_BIN="/opt/btcentral/bin/central"
CENTRAL_SRC="/opt/btcentral/central.c"
PORT=80

menu_main() {
  while true; do
    echo ""
    echo "  ╔════════════════════════════════╗"
    echo "  ║   BlackTunnel Central Server   ║"
    echo "  ╠════════════════════════════════╣"
    echo "  ║  1. Instalar / Actualizar      ║"
    echo "  ║  2. Reiniciar servicio         ║"
    echo "  ║  3. Gestionar usuarios         ║"
    echo "  ║  4. Gestionar servidores       ║"
    echo "  ║  5. Estado del servicio        ║"
    echo "  ║  0. Salir                      ║"
    echo "  ╚════════════════════════════════╝"
    printf "  › "; read -r op
    case "$op" in
      1) do_install ;;
      2) do_restart ;;
      3) menu_users ;;
      4) menu_servers ;;
      5) do_status ;;
      0) exit 0 ;;
    esac
  done
}

do_install() {
  echo ""
  echo "[*] Instalando..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -q 2>/dev/null || true
  apt-get install -y -q gcc ca-certificates

  mkdir -p "$USERS_DIR" /opt/btcentral/bin
  [ ! -f "$SERVERS_FILE" ] && touch "$SERVERS_FILE"

  cat > "$CENTRAL_SRC" << 'CSRC'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define PORT         80
#define USERS_DIR    "/var/lib/btcentral/users"
#define SERVERS_FILE "/var/lib/btcentral/servers.txt"
#define BUF          8192
#define MAXEV        1024
#define MAXCONNS     4096

typedef struct { int fd; char buf[BUF]; int len; } conn_t;
static conn_t *g_conns[MAXCONNS];
static int     g_ep;

static void fd_nodelay(int fd){
    int v=1;
    setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&v,sizeof(v));
    setsockopt(fd,IPPROTO_TCP,TCP_QUICKACK,&v,sizeof(v));
}
static void conn_close(conn_t *c){
    if(!c) return;
    epoll_ctl(g_ep,EPOLL_CTL_DEL,c->fd,NULL);
    close(c->fd);
    for(int i=0;i<MAXCONNS;i++) if(g_conns[i]==c){g_conns[i]=NULL;break;}
    free(c);
}
static void hget(const char *h, const char *key, char *out, int sz){
    out[0]=0;
    const char *p=strcasestr(h,key); if(!p) return;
    p+=strlen(key); while(*p==' ') p++;
    int i=0; while(*p&&*p!='\r'&&*p!='\n'&&i<sz-1) out[i++]=*p++;
    out[i]=0;
}
static void uget(const char *hwid, const char *key, char *out, int sz){
    out[0]=0;
    char path[512]; snprintf(path,sizeof(path),USERS_DIR"/%s",hwid);
    FILE *f=fopen(path,"r"); if(!f) return;
    char line[256]; int klen=strlen(key);
    while(fgets(line,sizeof(line),f)){
        if(strncmp(line,key,klen)==0&&line[klen]=='='){
            char *v=line+klen+1; int i=0;
            while(*v&&*v!='\r'&&*v!='\n'&&i<sz-1) out[i++]=*v++;
            out[i]=0; break;
        }
    }
    fclose(f);
}
static int days_left(const char *exp){
    if(!exp||!exp[0]) return 0;
    int ey,em,ed;
    if(sscanf(exp,"%d-%d-%d",&ey,&em,&ed)!=3) return 0;
    time_t now=time(NULL);
    struct tm t={0}; t.tm_year=ey-1900; t.tm_mon=em-1; t.tm_mday=ed; t.tm_isdst=-1;
    int d=(int)((mktime(&t)-now)/86400)+1;
    return d<0?0:d;
}
static int is_expired(const char *exp){
    if(!exp||!exp[0]) return 0;
    int ey,em,ed;
    if(sscanf(exp,"%d-%d-%d",&ey,&em,&ed)!=3) return 0;
    time_t now=time(NULL); struct tm *t=gmtime(&now);
    int cy=t->tm_year+1900,cm=t->tm_mon+1,cd=t->tm_mday;
    if(ey<cy) return 1; if(ey>cy) return 0;
    if(em<cm) return 1; if(em>cm) return 0;
    return ed<cd;
}
static void read_servers(char *out, int sz){
    out[0]=0;
    FILE *f=fopen(SERVERS_FILE,"r"); if(!f) return;
    char line[512]; int pos=0;
    while(fgets(line,sizeof(line),f)){
        char *p=line; while(*p==' '||*p=='\t') p++;
        int len=strlen(p);
        while(len>0&&(p[len-1]=='\r'||p[len-1]=='\n'||p[len-1]==' ')) p[--len]=0;
        if(!len) continue;
        if(pos>0&&pos<sz-1) out[pos++]=',';
        int n=snprintf(out+pos,sz-pos,"%s",p);
        pos+=n; if(pos>=sz-1) break;
    }
    fclose(f);
}
static void send101_close(conn_t *c, const char *extra){
    char buf[4096];
    snprintf(buf,sizeof(buf),
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "%s\r\n", extra?extra:"");
    send(c->fd,buf,strlen(buf),MSG_NOSIGNAL);
    conn_close(c);
}
static void handle_request(conn_t *c){
    c->buf[c->len]=0;
    char method[32]={0};
    sscanf(c->buf,"%31s",method);

    if(strcasecmp(method,"BT-SERVERS")==0){
        char servers[4096]={0};
        read_servers(servers,sizeof(servers));
        char extra[4200];
        snprintf(extra,sizeof(extra),"X-Servers: %s\r\n",servers);
        send101_close(c,extra); return;
    }

    if(strcasecmp(method,"BT-VERIFY")==0){
        char hw[128]={0};
        hget(c->buf,"Auth:",hw,sizeof(hw));
        if(!hw[0]){send101_close(c,"X-Status: INVALID\r\n");return;}
        for(char *p=hw;*p;p++) if(*p=='/'||*p=='.'||*p==' '){send101_close(c,"X-Status: INVALID\r\n");return;}
        char path[512]; snprintf(path,sizeof(path),USERS_DIR"/%s",hw);
        if(access(path,F_OK)!=0){send101_close(c,"X-Status: INVALID\r\n");return;}
        char name[64]={0},expire[32]={0},created[32]={0};
        uget(hw,"name",name,sizeof(name));
        uget(hw,"expire",expire,sizeof(expire));
        uget(hw,"created",created,sizeof(created));
        if(!name[0]) snprintf(name,sizeof(name),"%s",hw);
        if(is_expired(expire)){
            char extra[256];
            snprintf(extra,sizeof(extra),"X-Status: EXPIRED\r\nX-Name: %s\r\nX-Expire: %s\r\n",name,expire);
            send101_close(c,extra); return;
        }
        int unlimited=(expire[0]==0);
        int days=unlimited?0:days_left(expire);
        char extra[512];
        snprintf(extra,sizeof(extra),
            "X-Status: OK\r\nX-Name: %s\r\nX-Expire: %s\r\n"
            "X-Days-Left: %d\r\nX-Created: %s\r\nX-Premium: %d\r\n",
            name,unlimited?"unlimited":expire,days,created,unlimited);
        send101_close(c,extra); return;
    }

    conn_close(c);
}

int main(void){
    signal(SIGPIPE,SIG_IGN);
    int lfd=socket(AF_INET6,SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
    if(lfd<0) lfd=socket(AF_INET,SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
    int v=1;
    setsockopt(lfd,SOL_SOCKET,SO_REUSEADDR,&v,sizeof(v));
    setsockopt(lfd,SOL_SOCKET,SO_REUSEPORT,&v,sizeof(v));
    struct sockaddr_in6 sa6={.sin6_family=AF_INET6,.sin6_port=htons(PORT),.sin6_addr=in6addr_any};
    if(bind(lfd,(struct sockaddr*)&sa6,sizeof(sa6))<0){
        struct sockaddr_in sa4={.sin_family=AF_INET,.sin_port=htons(PORT),.sin_addr.s_addr=INADDR_ANY};
        bind(lfd,(struct sockaddr*)&sa4,sizeof(sa4));
    }
    listen(lfd,1024);
    g_ep=epoll_create1(EPOLL_CLOEXEC);
    struct epoll_event le={.events=EPOLLIN,.data.fd=lfd};
    epoll_ctl(g_ep,EPOLL_CTL_ADD,lfd,&le);
    struct epoll_event evs[MAXEV];
    for(;;){
        int n=epoll_wait(g_ep,evs,MAXEV,-1);
        for(int i=0;i<n;i++){
            if(evs[i].data.fd==lfd){
                int cfd=accept4(lfd,NULL,NULL,SOCK_NONBLOCK|SOCK_CLOEXEC);
                if(cfd<0) continue;
                fd_nodelay(cfd);
                conn_t *c=calloc(1,sizeof(*c)); c->fd=cfd;
                for(int j=0;j<MAXCONNS;j++) if(!g_conns[j]){g_conns[j]=c;break;}
                struct epoll_event ce={.events=EPOLLIN|EPOLLET|EPOLLRDHUP,.data.ptr=c};
                epoll_ctl(g_ep,EPOLL_CTL_ADD,cfd,&ce);
                continue;
            }
            conn_t *c=evs[i].data.ptr; if(!c) continue;
            if(evs[i].events&(EPOLLERR|EPOLLHUP|EPOLLRDHUP)){conn_close(c);continue;}
            ssize_t r=recv(c->fd,c->buf+c->len,BUF-1-c->len,0);
            if(r<=0){conn_close(c);continue;}
            c->len+=r; c->buf[c->len]=0;
            if(strstr(c->buf,"\r\n\r\n")||strstr(c->buf,"\n\n")) handle_request(c);
        }
    }
    return 0;
}
CSRC

  gcc -O2 -o "$CENTRAL_BIN" "$CENTRAL_SRC"
  chmod 755 "$CENTRAL_BIN"
  echo "[✓] Servidor central compilado"

  cat > /etc/systemd/system/btcentral.service << EOF
[Unit]
Description=BlackTunnel Central Server
After=network.target
[Service]
ExecStart=${CENTRAL_BIN}
Restart=always
RestartSec=2
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable btcentral
  systemctl restart btcentral

  IP=$(hostname -I | awk '{print $1}')
  echo ""
  echo "  [✓] Central instalado  IP=$IP:$PORT"
  echo "      usuarios : $USERS_DIR"
  echo "      servers  : $SERVERS_FILE"
}

do_restart(){
  systemctl restart btcentral && echo "  [✓] Reiniciado" || echo "  [!] Error"
}

do_status(){
  echo ""
  systemctl status btcentral --no-pager
  echo ""
  echo "  Servidores:"
  [ -s "$SERVERS_FILE" ] && _server_list_print || echo "    (ninguno)"
  echo ""
  echo "  Usuarios: $(ls $USERS_DIR 2>/dev/null | wc -l)"
}

# ── PARSEO DE LÍNEA DE SERVIDOR ──────────────────────────────────
_parse_server_line(){
  local line="$1"
  SERVER_HOST="${line%%(*}"
  local inner="${line#*(}"; inner="${inner%)*}"
  SERVER_REGION="${inner%%|*}"
  local rest="${inner#*|}"; SERVER_STATUS="${rest%%|*}"
}

_server_list_print(){
  local n=0
  printf "  %-3s  %-35s  %-10s  %s\n" "#" "Host" "Región" "Estado"
  echo "  $(printf '─%.0s' {1..60})"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$((n+1))
    _parse_server_line "$line"
    printf "  %-3s  %-35s  %-10s  %s\n" "$n" "$SERVER_HOST" "$SERVER_REGION" "$SERVER_STATUS"
  done < "$SERVERS_FILE"
}

# ── USUARIOS ─────────────────────────────────────────────────────
menu_users(){
  while true; do
    echo ""
    echo "  ┌──────────────────────────────┐"
    echo "  │      Gestión Usuarios        │"
    echo "  ├──────────────────────────────┤"
    echo "  │  1. Listar                   │"
    echo "  │  2. Agregar                  │"
    echo "  │  3. Editar                   │"
    echo "  │  4. Eliminar                 │"
    echo "  │  5. Eliminar varios          │"
    echo "  │  6. Editar identificador     │"
    echo "  │  0. Volver                   │"
    echo "  └──────────────────────────────┘"
    printf "  › "; read -r op
    case "$op" in
      1) user_list ;;
      2) user_add ;;
      3) user_edit ;;
      4) user_del ;;
      5) user_del_multi ;;
      6) user_edit_hwid ;;
      0) return ;;
    esac
  done
}

user_list(){
  echo ""
  printf "  %-4s  %-20s  %-36s  %-12s  %s\n" "Nro" "Nombre" "HWID" "Expira" "Estado"
  echo "  $(printf '─%.0s' {1..90})"
  local n=0
  for f in "$USERS_DIR"/*; do
    [ -f "$f" ] || continue
    n=$((n+1))
    local hwid name expire estado
    hwid=$(basename "$f")
    name=$(grep  "^name="   "$f" 2>/dev/null | cut -d= -f2)
    expire=$(grep "^expire=" "$f" 2>/dev/null | cut -d= -f2)
    [ -z "$name" ] && name="(sin nombre)"
    if [ -z "$expire" ]; then
      estado="ilimitado"; expire="∞"
    else
      local days=$(( ( $(date -d "$expire" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
      [ "$days" -lt 0 ] && estado="EXPIRADO" || estado="${days}d"
    fi
    printf "  %-4s  %-20s  %-36s  %-12s  %s\n" "$n" "$name" "$hwid" "$expire" "$estado"
  done
  [ "$n" -eq 0 ] && echo "  (ningún usuario)"
  echo ""
}

user_add(){
  echo ""
  printf "  HWID       : "; read -r hwid; [ -z "$hwid" ] && return
  printf "  Nombre     : "; read -r name
  printf "  Expira (YYYY-MM-DD, vacío=ilimitado): "; read -r expire
  { echo "name=${name}"; echo "created=$(date +%Y-%m-%d)"; echo "expire=${expire}"; } > "$USERS_DIR/$hwid"
  echo "  [✓] Agregado: ${name:-$hwid}"
}

user_edit(){
  echo ""
  user_list
  printf "  Número a editar: "; read -r sel
  local hwid
  hwid=$(ls "$USERS_DIR" 2>/dev/null | sed -n "${sel}p")
  [ -z "$hwid" ] && echo "  No encontrado." && return
  local f="$USERS_DIR/$hwid"
  local cur_name cur_exp
  cur_name=$(grep "^name="   "$f" | cut -d= -f2)
  cur_exp=$(grep  "^expire=" "$f" | cut -d= -f2)
  echo "  HWID   : $hwid"
  echo "  Nombre : $cur_name"
  echo "  Expira : ${cur_exp:-ilimitado}"
  printf "  Nuevo nombre (enter=sin cambio): "; read -r name
  printf "  Nueva expiración YYYY-MM-DD (enter=sin cambio, 'ilimitado'=sin vencimiento): "; read -r expire
  [ -n "$name" ]   && sed -i "s/^name=.*/name=${name}/" "$f"
  if [ "$expire" = "ilimitado" ]; then
    sed -i "s/^expire=.*/expire=/" "$f"
  elif [ -n "$expire" ]; then
    sed -i "s/^expire=.*/expire=${expire}/" "$f"
  fi
  echo "  [✓] Actualizado"
}

user_del(){
  echo ""
  user_list
  printf "  Número a eliminar: "; read -r sel
  local hwid
  hwid=$(ls "$USERS_DIR" 2>/dev/null | sed -n "${sel}p")
  [ -z "$hwid" ] && echo "  No encontrado." && return
  local name; name=$(grep "^name=" "$USERS_DIR/$hwid" 2>/dev/null | cut -d= -f2)
  printf "  Eliminar ${name:-$hwid}? (s/n): "; read -r confirm
  [ "$confirm" = "s" ] || return
  rm -f "$USERS_DIR/$hwid"
  echo "  [✓] Eliminado: ${name:-$hwid}"
}

user_del_multi(){
  echo ""
  user_list
  printf "  Números a eliminar (ej: 1,3,5,7): "; read -r seleccion
  [ -z "$seleccion" ] && return
  local all_hwids
  all_hwids=($(ls "$USERS_DIR" 2>/dev/null))
  local eliminados=0
  IFS=',' read -ra nums <<< "$seleccion"
  for num in "${nums[@]}"; do
    num=$(echo "$num" | tr -d ' ')
    local idx=$((num-1))
    local hwid="${all_hwids[$idx]}"
    [ -z "$hwid" ] && echo "  [!] Número $num no existe" && continue
    local name; name=$(grep "^name=" "$USERS_DIR/$hwid" 2>/dev/null | cut -d= -f2)
    rm -f "$USERS_DIR/$hwid"
    echo "  [✓] Eliminado: ${name:-$hwid}"
    eliminados=$((eliminados+1))
  done
  echo "  Total eliminados: $eliminados"
}

user_edit_hwid(){
  echo ""
  user_list
  printf "  Número del usuario a reasignar HWID: "; read -r sel
  local hwid_old
  hwid_old=$(ls "$USERS_DIR" 2>/dev/null | sed -n "${sel}p")
  [ -z "$hwid_old" ] && echo "  No encontrado." && return
  local name; name=$(grep "^name=" "$USERS_DIR/$hwid_old" 2>/dev/null | cut -d= -f2)
  echo "  Usuario : ${name:-$hwid_old}"
  echo "  HWID actual: $hwid_old"
  printf "  Nuevo HWID: "; read -r hwid_new
  [ -z "$hwid_new" ] && return
  [ -f "$USERS_DIR/$hwid_new" ] && echo "  [!] Ese HWID ya existe." && return
  cp "$USERS_DIR/$hwid_old" "$USERS_DIR/$hwid_new"
  rm -f "$USERS_DIR/$hwid_old"
  echo "  [✓] HWID actualizado: $hwid_old → $hwid_new"
}

# ── SERVIDORES ───────────────────────────────────────────────────
menu_servers(){
  while true; do
    echo ""
    echo "  ┌──────────────────────────────┐"
    echo "  │      Gestión Servidores      │"
    echo "  ├──────────────────────────────┤"
    echo "  │  1. Listar                   │"
    echo "  │  2. Agregar                  │"
    echo "  │  3. Editar                   │"
    echo "  │  4. Eliminar                 │"
    echo "  │  0. Volver                   │"
    echo "  └──────────────────────────────┘"
    printf "  › "; read -r op
    case "$op" in
      1) server_list ;;
      2) server_add ;;
      3) server_edit ;;
      4) server_del ;;
      0) return ;;
    esac
  done
}

server_list(){
  echo ""
  [ -s "$SERVERS_FILE" ] && _server_list_print || echo "  (ningún servidor)"
  echo ""
}

server_add(){
  echo ""
  printf "  Host/dominio : "; read -r host;   [ -z "$host" ]   && return
  printf "  Región       : "; read -r region; [ -z "$region" ] && return
  printf "  Estado (online/offline): "; read -r status
  [ -z "$status" ] && status="online"
  echo "${host}(${region}|${status})" >> "$SERVERS_FILE"
  echo "  [✓] Agregado: ${host}(${region}|${status})"
}

server_edit(){
  echo ""
  server_list
  printf "  Número a editar: "; read -r n
  [ -z "$n" ] && return
  local line; line=$(sed -n "${n}p" "$SERVERS_FILE")
  [ -z "$line" ] && echo "  No encontrado." && return
  _parse_server_line "$line"
  echo "  Host   : $SERVER_HOST"
  echo "  Región : $SERVER_REGION"
  echo "  Estado : $SERVER_STATUS"
  printf "  Nueva región  (enter=sin cambio): "; read -r new_region
  printf "  Nuevo estado  (enter=sin cambio): "; read -r new_status
  [ -z "$new_region" ] && new_region="$SERVER_REGION"
  [ -z "$new_status" ] && new_status="$SERVER_STATUS"
  local new_line="${SERVER_HOST}(${new_region}|${new_status})"
  python3 -c "
import sys
path,n,new=sys.argv[1],int(sys.argv[2]),sys.argv[3]
lines=open(path).readlines()
lines[n-1]=new+'\n'
open(path,'w').writelines(lines)
" "$SERVERS_FILE" "$n" "$new_line"
  echo "  [✓] Actualizado: $new_line"
}

server_del(){
  echo ""
  server_list
  printf "  Número a eliminar: "; read -r n
  [ -z "$n" ] && return
  sed -i "${n}d" "$SERVERS_FILE"
  echo "  [✓] Eliminado"
}

case "${1:-}" in
  install) do_install ;;
  restart) do_restart ;;
  status)  do_status ;;
  users)   menu_users ;;
  servers) menu_servers ;;
  "")      menu_main ;;
esac
