---
columns: 2
---
# machine

```shell every=1 chart wide height=10 title="load average"
cat /proc/loadavg
```

```shell every=2 chart=area height=8 title="memory used, MiB"
free -m | awk '/Mem:/ { print $3 }'
```

```shell every=5 chart="bar RESTARTS" height=8 title="restarts by pod"
kubectl get pods
```
