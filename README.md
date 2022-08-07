# Replication Manager NG
Stateless async replication manager for PXC Clusters
## What does it mean stateless?
Replication Manager NG does not write anything into the database and does not keep any track of current replication topology. Based on known cluster topology and a set of rules, each node in the replica cluster is able to know if he must assume the role of replicating data.
As a topology manager, we care only about the **io_thread** status, we do not check **sql_thread** status. This means that you need to monitor if replication events are being applied successfully or latency is increasing.
## How does it work?
We have three tables that you need to fill with data previously. One table contains replication metadata: user, password... The other two tables contain information about the source cluster and the replica cluster. We execute a database procedure, in each node, that retrives the configuration data and analyzes two things: replication status and node availability. With this information we are able to decide if the node should be running the replication threads or not.
## Sounds great, but could you provide more details?
Of course. This is what the procedure does:
1. Check node health in the cluster. If the wsrep_ready is not 'ON', then we do nothing and quit.
2. Check if the node is member of the replica cluster. If it is not, we remove all the replication configuration and quit.
3. Check if there is a node in the replica cluster with a lesser value of priority. If there is, we should not run replication locally. We remove all the replication configuration and quit.
4. Check if replication is running. If it is running then do nothing and quit.
5. Check if replication is configured. If it is not, then configure it pointing to the source node with less priority and quit.
6. If replication is configured and not running, get the following source node in the topology and configure replication pointing to it, then quit.
## How do I install it?
1. Configure replication from the source cluster to the replica. Use a channel, you will need to use that channel later. If replication is not running, you should not continue. As a general recommendation, although it is not strictly required, run all your slaves with auto start of replication disabled (skip-slave-start). This is important to avoid a node starting replication after a crash.
2. Create the tables and procedure. Make sure that you install both on the same database. For example you can run:

```
$ mysql -e "create database percona"
$ mysql percona < create_tables.sql
$ mysql percona < replication_managerng.sql
```

Although it is an untested feature, you could install everything on different databases to run more complex replication topologies. Be careful, the more complex a replication topology is, the more issues you never thought of will appear. Keep your topology as simple as possible.

3. Configure the metadata table. Here you have a sample configuration.

| meta_key             | meta_value            |
| -------------------- | --------------------- |
| replication_channel  | test_channel          |
| replication_password | Replication_password1 |
| replication_ssl      | 1                     |
| replication_user     | replication_user      |

**replication_channel** is the name of replication channel you configured in step 1.

**replication_password** is the password used for replication.

**replication_ssl** if ssl should be enabled.

**replication_user** the username used for replication.

The sql code to insert data into the metadata table is like this:

```insert into replication_metadata values ('replication_channel','my_replication_channel');```

Use similar code to insert data on the other tables. But you should have some sql knowledge if you want to use this tool.

4. Configure the topology tables.
These two tables, **source_cluster** and **replica_cluster** contain the nodes and priorities assigned.
Source cluster:

| cluster   | node_priority | node_name | node_address |
| --------- | ------------- | --------- | -------------|
| clusterT1 |             1 | mysql1-T1 | 10.11.30.208 |
| clusterT1 |             2 | mysql2-T1 | 10.11.72.237 |
| clusterT1 |             3 | mysql3-T1 | 10.11.13.109 |

**cluster** corresponds to the cluster name in pxc, but it is not used currently.

**node_priority** defines for the source cluster what is the order hosts will be tested. If a server has to be configured from scratch, it will configure replication to the lowest priority host. If replication is already configured and it is broken, it will try with the following node. 

**node_name** and **node_address** are the node_name and node_address.

Replica cluster:

| cluster   | node_priority | node_name | node_address  |
| --------- | ------------- | --------- | ------------- |
| clusterT2 |             1 | mysql1-T2 | 10.11.153.62  |
| clusterT2 |             2 | mysql2-T2 | 10.11.110.195 |
| clusterT2 |             3 | mysql3-T2 | 10.11.13.216  |

**cluster** corresponds to the cluster name in pxc, but it is used to find the nodes in my cluster with less priority.

**node_priority** the available node that has the lesser priority will run replication.

**node_name** and **node_address** are the node_name and node_address.

5. Call the procedure on each node.

You just need to use your favorite too to execute this procedure on each node periodically. If you write a cronjob to execute the procedure on each node every minute, that's fine.

I don't recommend using database events because enabling events on replicas can generate errant GTIDs.
## Hey, the sql thread crashed and replication was not fixed... what's wrong?
We monitor replication topology, not overall replication health. Usually, a problem with replication that appears in when sql code is executed will not be fixed by repointing replicas. You need to fix this before.
## Hey, we were XXXXX seconds behing master and the application made all the relay logs disappear. What has happened?
The application can issue a `reset replica all` or a `change master`, in both cases your relay logs will disappear. Make sure that you do not purge the binary logs in the server. I added a safeguard that, if the io_thread is not running, it will not issue a change master until all the pending events have been applied. But this only works if does not join the replica cluster a node with better priority.
## Why do you say better priority instead of higher o lower priority?
Nodes with lower priority values have higher priority. Less is more. This is a bit confusing, this is why I use the word better.
## Why don't you use the metadata table to configure the logging instead of using a parameter?
In case of replication latency this change would be applied when all the pending events are applied. By using a parameter, you can enable or disable logging without worrying about replication delays.
## I changed replica priorities and nothing happened.
Did you change the replica priorities while replication was broken or there was replication delay? This is the most probable cause.
## I changed the source priorities and nothing happened.
Source priorities are enforced only when there is a failure, otherwise they are ignored. And they just define the order of connection to the source servers when replication stops. To fix this: make sure there is not replication lag, stop the io_thread and run replication_managerng. Repeat as many times as needed to have replication pointing to the desired node.
## Anything else I should know?
Replication_managerng can configure replication to any of the replication sources as long as it is able to reach it. If there is a partition on your source cluster, the nodes in the minoritary partition can be used as sources for replication. While we plan to fix this in future versions, it is always a good idea to fence or Stonith nodes that are not valid members of a cluster.
## Do you offer any gold support contract for this product?
This is an open source product. You have two options, one is filling a bug in github and wait until somebody fixes it. There is another (better) option. Read the code, fix the issue and submit the fix. I wrote the code with a lot of comments to reduce the barrier of entry.
## Why NG?
This work is partially based on ideas borrowed from [Yves Trudeau](https://github.com/y-trudeau). You can find his script to manage replication here: [replication_manager.sh](https://github.com/y-trudeau/Mysql-tools/tree/master/PXC)
## I installed this software on my production environment and now my house is burning?
Please read the license. Sections 15, 16 and 17.
