-- IMPORTANT: Execute all configuration scripts only on one node
-- on the source cluster. Make sure that replication is running
-- between both clusters before trying to configure anything.

DROP PROCEDURE IF EXISTS replication_managerng;
DELIMITER //
CREATE PROCEDURE replication_managerng()
  BEGIN
  /* DO NOT EXECUTE IT if the aux tables do not exist or do not contain the correct information. */
     
  DECLARE node_ready, cluster_name, my_name, node_candidate, old_source_host, new_source_host,
          replication_channel, replication_user, replication_password, replication_ssl VARCHAR(256);
  DECLARE counter_variable, my_priority, found INTEGER;
  DECLARE incoming_addresses VARCHAR(1024);
  
  SELECT variable_value INTO node_ready
  FROM performance_schema.global_status WHERE variable_name='wsrep_ready';
  /* IF the node is not ready, we do nothing */

  SELECT node_ready AS message;

  IF node_ready = 'ON' THEN
    /* Lets retrieve operational information */
    SELECT meta_value INTO replication_channel
	FROM replication_metadata
    WHERE meta_key = 'replication_channel';
  
    SELECT variable_value INTO my_name
    FROM performance_schema.global_variables WHERE variable_name='wsrep_node_name';
    
    SELECT variable_value INTO cluster_name
    FROM performance_schema.global_variables WHERE variable_name='wsrep_cluster_name';

    /* If I'm present in the source_cluster table, this means that I am not a replica */
    SELECT count('x') INTO counter_variable
    FROM source_cluster
    WHERE cluster=cluster_name
      AND node_name=my_name;

    SELECT replication_channel, my_name, cluster_name, counter_variable AS am_i_source;

    IF counter_variable = 0 THEN
      /* If I'm here, I should be a replica, but we will verify anyway */
      SELECT count('x') INTO counter_variable
      FROM replica_cluster
      WHERE cluster=cluster_name
        AND node_name=my_name;

      SELECT counter_variable AS am_i_replica, my_name, cluster_name;

      IF counter_variable = 1 THEN
        /* this is the format of  wsrep_incoming_addresses
        10.11.30.208:3306,10.11.13.109:3306,10.11.72.237:3306 */
        /* Lets retrieve our priority */
        SELECT node_priority INTO my_priority
        FROM replica_cluster
        WHERE cluster=cluster_name
          AND node_name=my_name;

        SELECT my_name, cluster_name, my_priority;

        SET counter_variable = 1;

        check_live_servers: WHILE counter_variable < my_priority DO
           /* We need to check that, at least, one of the nodes
              with more priority is connected to the cluster */
           SELECT node_address INTO node_candidate
           FROM replica_cluster
           WHERE cluster=cluster_name
             AND node_priority=counter_variable;

           SELECT variable_value
           INTO incoming_addresses
           FROM performance_schema.global_status
           WHERE variable_name = 'wsrep_incoming_addresses';

           SELECT node_candidate, incoming_addresses;

           SET found = LOCATE(node_candidate, incoming_addresses);

           IF found != 0 THEN
               /* We've found a server with more priority and member of the cluster */
               SELECT 'Found candidate' AS message;
               LEAVE check_live_servers;
           END IF;

           SET counter_variable = counter_variable + 1;

        END WHILE check_live_servers;

        IF counter_variable = my_priority THEN
           /* or my_priority was one or I haven't found any active node with more prority */
           SELECT count('x') INTO counter_variable
           FROM performance_schema.replication_connection_status
           WHERE service_state = 'ON'
             AND channel_name = replication_channel;

           /* If replication is not running (there are no io_threads running) */
           IF counter_variable = 0 THEN
              /* Here I need to setup replication */
              select 'Configure replication';
              SELECT count('x') INTO counter_variable
              FROM performance_schema.replication_connection_status
			  WHERE channel_name = replication_channel;
		      
              IF counter_variable = 0 THEN
                 /* Replication is not configured */
                 /* We configure the node with the lower priority */
                 SELECT node_name
                 INTO new_source_host
                 FROM source_cluster
                 WHERE cluster LIKE '%'
                 ORDER BY node_priority ASC
                 LIMIT 1;
                 
                 SELECT new_source_host;

                 /* Lets retrieve the replication configuration we need to proceed. */
				 SELECT meta_value INTO replication_user
                 FROM replication_metadata
                 WHERE meta_key = 'replication_user';
                 
                 SELECT meta_value INTO replication_password
				 FROM replication_metadata
                 WHERE meta_key = 'replication_password';
                 
                 SELECT meta_value INTO replication_ssl
                 FROM replication_metadata
                 WHERE meta_key = 'replication_ssl';

                 /* SELECT replication_user, replication_password, replication_ssl; */
                 SELECT replication_user, replication_ssl;
                                  
				 /* Configure the new one */
                 SET @cmd = CONCAT('CHANGE MASTER TO ',
                                   'MASTER_HOST=\'', new_source_host, '\', ',
				   'MASTER_USER=\'', replication_user, '\', ',
				   'MASTER_PASSWORD=\'', replication_password, '\', ',
                                   'MASTER_SSL=', replication_ssl, ', ',
                                   'MASTER_AUTO_POSITION=1 ',
                                   'FOR CHANNEL \'',replication_channel, '\'');

				 /* select @cmd; */
                 PREPARE stmt FROM @cmd;
                 EXECUTE stmt;
                 DROP PREPARE stmt;

                 /* And start it */
                 SET @cmd = CONCAT('START SLAVE FOR CHANNEL \'',replication_channel,'\'');
                 PREPARE stmt FROM @cmd;
                 EXECUTE stmt;
                 DROP PREPARE stmt;

                 SELECT 'Replication started.' AS message;

              ELSE
                 /* Replication is configured but stopped */
                 /* If replication is stopped, we assume that it is failing */
                 /* THIS MEANS THAT WE WILL FIX REPLICATION IF SOMEBODY STOPS IT MANUALLY */
                 SELECT host INTO old_source_host
                 FROM performance_schema.replication_connection_configuration
                 WHERE channel_name = replication_channel;
              
                 select old_source_host;
              
                 /* We don't know the name of the source cluster... 
                    for this to work, we need a host to appear only once in the table */
				/* THIS MEANS THAT THIS CODE WORKS FOR ONLY SINGLE SOURCE CLUSTER */
                /* A possible workaround is installing the metadata and the event on 
                   diferent databases. Then activate the event selectively.
                   WARNING: This solution hasn't been tested */
			     SELECT node_priority INTO my_priority
			     FROM source_cluster
			     WHERE cluster LIKE '%'
			     AND node_name=old_source_host;
              
                 /* We return the following priority value, we are not using always
                    the node with the higher priority because we don't know if it
                    is available. We will test replication in a cycle. */
                 SELECT ( my_priority ) % count(*) + 1  INTO counter_variable
                 FROM replica_cluster
                 WHERE cluster=cluster_name;

                 /* Once we have the priority, we retrieve the host that has
                    that priority */
                 SELECT node_name
                 INTO new_source_host
                 FROM source_cluster
                 WHERE cluster LIKE '%'
                 AND node_priority = counter_variable;
                 
                 SELECT old_source_host, my_priority, new_source_host, counter_variable;

                 /* Lets retrieve the replication configuration we need to proceed. */
				 SELECT meta_value INTO replication_user
                 FROM replication_metadata
                 WHERE meta_key = 'replication_user';
                 
                 SELECT meta_value INTO replication_password
				 FROM replication_metadata
                 WHERE meta_key = 'replication_password';
                 
                 SELECT meta_value INTO replication_ssl
                 FROM replication_metadata
                 WHERE meta_key = 'replication_ssl';

                 /* SELECT replication_user, replication_password, replication_ssl; */
                 SELECT replication_user, replication_ssl;
                 
                 /* Make sure that everything is stopped before changing replication. */
                 SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
                 PREPARE stmt FROM @cmd;
                 EXECUTE stmt;
                 DROP PREPARE stmt;
                 
                 /* Remove the old configuration */
                 SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
                 PREPARE stmt FROM @cmd;
                 EXECUTE stmt;
                 DROP PREPARE stmt;

		 /* Configure the new one */
                 SET @cmd = CONCAT('CHANGE MASTER TO ',
                                   'MASTER_HOST=\'', new_source_host, '\', ',
				   'MASTER_USER=\'', replication_user, '\', ',
				   'MASTER_PASSWORD=\'', replication_password, '\', ',
                                   'MASTER_SSL=', replication_ssl, ', ',
                                   'MASTER_AUTO_POSITION=1 ',
                                   'FOR CHANNEL \'',replication_channel, '\'');

		 /* select @cmd; */
                 PREPARE stmt FROM @cmd;
                 EXECUTE stmt;
                 DROP PREPARE stmt;

                 /* And start it */
                 SET @cmd = CONCAT('START SLAVE FOR CHANNEL \'',replication_channel,'\'');
                 PREPARE stmt FROM @cmd;
                 EXECUTE stmt;
                 DROP PREPARE stmt;

                 SELECT 'Replication started.' AS message;

              END IF;

	   ELSE
              /* Replication is running */
              select 'Do nothing: Replication is running';
           END IF;

        ELSE
           /* If counter_variable is not equal to my_priority, this means that we've found
              a server with higher priority and we need to make sure we're not replicating */
           SELECT 'Clear replication: server active with more priority';
           
           SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
           PREPARE stmt FROM @cmd;
           EXECUTE stmt;
           DROP PREPARE stmt;

           SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
           PREPARE stmt FROM @cmd;
           EXECUTE stmt;
           DROP PREPARE stmt;

        END IF;
      ELSE
         /* I'm not a replica... I stop replication just in case */
         SELECT 'Clear replication: I am not a replica.';
         
	 SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
	 PREPARE stmt FROM @cmd;
	 EXECUTE stmt;
	 DROP PREPARE stmt;

	 SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
	 PREPARE stmt FROM @cmd;
	 EXECUTE stmt;
	 DROP PREPARE stmt;
      END IF;
    ELSE
      /* I'm a master... I stop replication just in case */
      select 'Clear replication: I am a member of the master cluster';

      SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
      PREPARE stmt FROM @cmd;
      EXECUTE stmt;
      DROP PREPARE stmt;

      SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
      PREPARE stmt FROM @cmd;
      EXECUTE stmt;
      DROP PREPARE stmt;

    END IF;
  END IF;
 END //

DELIMITER ;
