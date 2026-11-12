#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <assert.h>
int main(void) {
 int p[2]; assert(pipe(p)==0); int inherited=dup(p[0]); assert(inherited>=0);
 assert(fcntl(p[1],F_SETNOSIGPIPE,1)==0);close(p[0]);
 ssize_t result=write(p[1],"response",8);printf("pipe with inherited reader: %zd bytes accepted\n",result);assert(result==8);
 close(inherited);errno=0;result=write(p[1],"response",8);assert(result==-1 && errno==EPIPE);close(p[1]);
 int s[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,s)==0);inherited=dup(s[0]);assert(inherited>=0);
 assert(fcntl(s[1],F_SETNOSIGPIPE,1)==0);assert(shutdown(s[1],SHUT_WR)==0);close(s[0]);
 errno=0;result=write(s[1],"response",8);printf("write-shutdown endpoint with retained reader: result %zd errno %d\n",result,errno);assert(result==-1 && errno==EPIPE);
 close(inherited);close(s[1]);return 0;
}
