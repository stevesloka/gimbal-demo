# Gimbal Demo

 This is a sample repo which spins up 3 Kubernetes clusters using KinD. It is used to demonstrate Contour, Gimbal, as well as httpproxy. 

## Curl 

```bash
$ while sleep 1; do curl http://marketing.pixelproxy.net/blog ; done
```

## Sample Apps

```
$ docker run --restart always -d -p 8080:8080 stevesloka/echo-server echo-server --echotext="This is app01!"
```