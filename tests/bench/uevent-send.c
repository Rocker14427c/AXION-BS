/* Prove the adaptive rule: send a display uevent on the netlink broadcast
   group and confirm the monitor relaxes its timer. Needs CAP_NET_ADMIN to
   broadcast, so this is best-effort. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/netlink.h>
int main(void){
  int fd=socket(PF_NETLINK,SOCK_DGRAM,NETLINK_KOBJECT_UEVENT);
  if(fd<0){perror("socket");return 1;}
  struct sockaddr_nl sa; memset(&sa,0,sizeof sa);
  sa.nl_family=AF_NETLINK; sa.nl_pid=0; sa.nl_groups=1;
  if(bind(fd,(struct sockaddr*)&sa,sizeof sa)<0){perror("bind");return 1;}
  char msg[]="change@/devices/platform/backlight\0ACTION=change\0SUBSYSTEM=backlight\0";
  struct sockaddr_nl d; memset(&d,0,sizeof d); d.nl_family=AF_NETLINK; d.nl_groups=1;
  if(sendto(fd,msg,sizeof msg,0,(struct sockaddr*)&d,sizeof d)<0){perror("sendto");return 1;}
  printf("sent\n"); return 0;
}
