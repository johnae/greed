# Machine

How busy this machine is, as it goes:

```shell every=1
cat /proc/loadavg | chart
```

The pods that aren't running:

```shell id=pods
kubectl get pods
```

```shell input=pods
where STATUS != Running | select NAME,STATUS,RESTARTS
```
