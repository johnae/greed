# Machine

How busy this machine is, now and as it goes.

```shell every=1
cat /proc/loadavg | chart
```

The largest files here:

```shell
ls | sort size -r | first 5 | chart size
```
