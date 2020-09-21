FROM debian:buster-slim

WORKDIR /bin/
RUN apt-get update
RUN apt-get install wget daemontools -y

RUN wget https://github.com/iizotov/flog/releases/download/aws-jam/flog
RUN chmod +x /bin/flog

ENTRYPOINT ["/bin/flog"]
