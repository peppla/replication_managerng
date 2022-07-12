-- IMPORTANT: Execute all configuration scripts only on one node
-- on the source cluster. Make sure that replication is running
-- between both clusters before trying to configure anything.

-- IMPORTANT: Replication must be configured using the correct
-- replication channel.

-- DESCRIPTIOM:
-- Tables to store the description of source and replica clusters
-- We also store replication metadata required to configure replication


-- This table contains the replication replica cluster
-- Use the pxc cluster name, node name and sequential priorities starting
-- from 1. The node with priority one will usually be the one running
-- the replication threads. If this node is not available, then
-- the following will start replication. When the first node returns to
-- the cluster, situation should return to initial status.

CREATE TABLE `replica_cluster` (
  `cluster` varchar(256) NOT NULL,
  `node_priority` int NOT NULL,
  `node_name` varchar(256) NOT NULL,
  `node_address` varchar(256) NOT NULL,
  PRIMARY KEY (`cluster`,`node_priority`),
  UNIQUE KEY `cluster` (`cluster`,`node_name`),
  UNIQUE KEY `cluster_2` (`cluster`,`node_address`)
);

-- This table contains the replication source cluster
-- Use the pxc cluster name, node name and sequential priorities starting
-- from 1. The node with priority one will usually be the one the replica
-- connects. If this node is not available, then the replica will connect
-- to the following one. When the first node returns to the cluster, 
-- NOTHING HAPPENS. Remember that this is a stateless replication manager,
-- this means that we can't know the previous status of a node.
-- If no nodes are available, then it will poll each node sequentially,
-- until one of the nodes becomes available.
CREATE TABLE `source_cluster` (
  `cluster` varchar(256) NOT NULL,
  `node_priority` int NOT NULL,
  `node_name` varchar(256) NOT NULL,
  `node_address` varchar(256) NOT NULL,
  PRIMARY KEY (`cluster`,`node_priority`),
  UNIQUE KEY `cluster` (`cluster`,`node_name`)
);

-- Data needed to configure replication:
-- +----------------------+-----------------------+
-- | meta_key             | meta_value            |
-- +----------------------+-----------------------+
-- | replication_channel  | test_channel          |
-- | replication_password | Replication_password1 |
-- | replication_ssl      | 1                     |
-- | replication_user     | replication_user      |
-- +----------------------+-----------------------+
-- I think it is quite self explanatory.

CREATE TABLE `replication_metadata` (
  `meta_key` varchar(256) NOT NULL,
  `meta_value` varchar(256) NOT NULL,
  PRIMARY KEY (`meta_key`)
);

