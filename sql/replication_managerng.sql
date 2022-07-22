-- IMPORTANT: Execute all configuration scripts only on one node
-- on the source cluster. Make sure that replication is running
-- between both clusters before trying to configure anything.

DROP PROCEDURE IF EXISTS replication_managerng;
DELIMITER //
CREATE PROCEDURE replication_managerng(logging INTEGER)
   BEGIN
   /* DO NOT EXECUTE IT if the aux tables do not exist or do not contain the correct information. */
   /* Call with logging = 0 if you want to get rid of the logging messages */

   DECLARE node_ready, cluster_name, my_name, node_candidate, old_source_host, new_source_host,
      replication_channel, replication_user, replication_password, replication_ssl VARCHAR(256);
   DECLARE counter_variable, my_priority, found INTEGER;
   DECLARE incoming_addresses VARCHAR(1024);
   DECLARE received_transactions LONGTEXT;

   /* Configuration of the Poorman Logger (TM) */
   /* use this combination to log messages */
   /*  SET @message =  CONCAT('This is the message I want to deliver: ',<variable>); */
   /*  IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF; */
   SET @pml = 'select now() time, if(?,\'ERROR\',\'LOG\') as level, ? as message';
   PREPARE poor_man_logger FROM @pml;
   SET @level = 0;

   /* IF the node is not ready, we do nothing */
   /* This query is writen like this to make it work even if we're not running pxc */
   SELECT IF(count(*),'ON','No ON')
   INTO node_ready
   FROM performance_schema.global_status
   WHERE variable_name='wsrep_ready'
     AND variable_value='ON';

   SET @message =  CONCAT('Node reported wsrep_ready: ',node_ready);
   IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

   IF node_ready = 'ON' THEN
      /* Lets retrieve operational information */
      /* This is the name of the replication channel */
      SELECT meta_value
      INTO replication_channel
      FROM replication_metadata
      WHERE meta_key = 'replication_channel';

      /* This is my hostname as seen by pxc, use a consistent naming */
      /* And names must be unique across all the clusters! */
      SELECT variable_value
      INTO my_name
      FROM performance_schema.global_variables
      WHERE variable_name='wsrep_node_name';

      /* This is the name of the cluster */
      SELECT variable_value
      INTO cluster_name
      FROM performance_schema.global_variables
      WHERE variable_name='wsrep_cluster_name';

      /* If I'm present in the source_cluster table, this means that I am not a replica */
      SELECT count('x')
      INTO counter_variable
      FROM source_cluster
      WHERE cluster=cluster_name
         AND node_name=my_name;

      SET @message =  CONCAT('Replication channel: ',replication_channel,', node_name: ', my_name, ', cluster_name: ', cluster_name, ', i_am_source: ', counter_variable);
      IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

      IF counter_variable = 0 THEN
         /* If I'm here, I should be a replica, but we will verify anyway 
            but maybe the configuration is wrong and I´m not in the source
            table neither the replica table. */
         SELECT count('x')
         INTO counter_variable
         FROM replica_cluster
         WHERE cluster=cluster_name
            AND node_name=my_name;

         SET @message =  CONCAT('Replication channel: ',replication_channel,', node_name: ', my_name, ', cluster_name: ', cluster_name, ', i_am_replica: ', counter_variable);
         IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

         IF counter_variable = 1 THEN
            /* this is the format of  wsrep_incoming_addresses
            10.11.30.208:3306,10.11.13.109:3306,10.11.72.237:3306 */
            /* Lets retrieve our priority */
            SELECT node_priority
            INTO my_priority
            FROM replica_cluster
            WHERE cluster=cluster_name
            AND node_name=my_name;

            SET @message =  CONCAT('Replication channel: ',replication_channel,', node_name: ', my_name, ', cluster_name: ', cluster_name, ', my_priority: ', my_priority);
            IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

            SET counter_variable = 1;

            /* We check the list of active servers to find a server with better priority */
            check_live_servers: WHILE counter_variable < my_priority DO
               /* We need to check that, at least, one of the nodes
               with more priority is connected to the cluster */
               SELECT node_address
               INTO node_candidate
               FROM replica_cluster
               WHERE cluster=cluster_name
                  AND node_priority=counter_variable;

               /* Retrieve the list of servers that are currently members of the cluster */
               SELECT variable_value
               INTO incoming_addresses
               FROM performance_schema.global_status
               WHERE variable_name = 'wsrep_incoming_addresses';

               SET @message =  CONCAT('Node_candidate: ',node_candidate,', incoming_addresses: ', incoming_addresses);
               IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

               /* Is the server from the replica table in the list of available servers? */
               SET found = LOCATE(node_candidate, incoming_addresses);

               IF found != 0 THEN
                  /* We've found a server with better priority and member of the cluster */
                  
                  SET @message =  CONCAT('Found node candidate');
                  IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
                  
                  LEAVE check_live_servers;
               END IF;
               /* If the server is not part of the cluster, then let's check another one */
               SET counter_variable = counter_variable + 1;
            END WHILE check_live_servers;

            IF counter_variable = my_priority THEN
               /* or my_priority was one or I haven't found any active node with more prority */
               SELECT count('x')
               INTO counter_variable
               FROM performance_schema.replication_connection_status
               WHERE service_state = 'ON'
                  AND channel_name = replication_channel;

               /* If replication is not running (there are no io_threads running) */
               IF counter_variable = 0 THEN
                  /* Here I need to setup replication */

                  SET @message =  CONCAT('Configuring replication');
                  IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
                  
                  /* Is there any configuration with our channel name */
                  SELECT count('x')
                  INTO counter_variable
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

                     SET @message =  CONCAT('This is the new source: ', new_source_host);
                     IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                     /* Lets retrieve the replication configuration we need to proceed. */
                     SELECT meta_value
                     INTO replication_user
                     FROM replication_metadata
                     WHERE meta_key = 'replication_user';

                     SELECT meta_value
                     INTO replication_password
                     FROM replication_metadata
                     WHERE meta_key = 'replication_password';

                     SELECT meta_value
                     INTO replication_ssl
                     FROM replication_metadata
                     WHERE meta_key = 'replication_ssl';

                     SET @message =  CONCAT('Replication_user: ', replication_user,', replication_ssl:', replication_ssl);
                     IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                     /* Configure the new one */
                     SET @cmd = CONCAT('CHANGE MASTER TO ',
                        'MASTER_HOST=\'', new_source_host, '\', ',
                        'MASTER_USER=\'', replication_user, '\', ',
                        'MASTER_PASSWORD=\'', replication_password, '\', ',
                        'MASTER_SSL=', replication_ssl, ', ',
                        'MASTER_AUTO_POSITION=1 ',
                        'FOR CHANNEL \'',replication_channel, '\'');

                     PREPARE stmt FROM @cmd;
                     EXECUTE stmt;
                     DROP PREPARE stmt;

                     /* And start it */
                     SET @cmd = CONCAT('START SLAVE FOR CHANNEL \'',replication_channel,'\'');
                     PREPARE stmt FROM @cmd;
                     EXECUTE stmt;
                     DROP PREPARE stmt;

                     SET @message =  CONCAT('Replication started using ', new_source_host ,' as replication source.');
                     IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                  ELSE
                     /* Replication is configured but stopped */
                     /* If replication is stopped, we assume that it is failing */
                     /* We will check if the sql_thread is running and, it it is, and 
                        there is latency, we will do nothing. To avoid losing relay logs
                        that could be applied */
                     /* THIS MEANS THAT WE WILL FIX REPLICATION IF SOMEBODY STOPS IT MANUALLY */

                     /* If replication (SQL_THREAD) is stopped, then we can switch master */
                     SELECT count(*)
                     INTO counter_variable
                     FROM performance_schema.replication_applier_status
                     WHERE channel_name = replication_channel
                       AND service_state = 'ON';

                     IF (counter_variable != 0) THEN
                        /* If the sql_thread is running, we need to verify if there are
                           pending events to apply */
                        /* We have the received transaction set */
                        SELECT received_transaction_set
                        INTO received_transactions
                        FROM performance_schema.replication_connection_status
                        WHERE channel_name = replication_channel;

                        /* We check if the transactions have been applied. */
                        SELECT wait_for_executed_gtid_set(received_transactions,1)
                        INTO counter_variable;

                        /* This is the trick: wait_for_executed_gtid_set will exit
                           immediately if all the transactions have been applied.
                           It will return 0. If transactions have not been applied,
                           it will wait for 1 second timeout and return 1 */
                     END IF;

                     /* If all the received gtids have been applied and, as the io_thread
                        is stopped too, it is safe to switch to a different server */
                     IF (counter_variable = 0) THEN

                        SET @message =  CONCAT('No latency detected: ',counter_variable);
                        IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                        SELECT host
                        INTO old_source_host
                        FROM performance_schema.replication_connection_configuration
                        WHERE channel_name = replication_channel;

                        SET @message =  CONCAT('This is the old source: ', old_source_host);
                        IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                        /* We don't know the name of the source cluster...
                           for this to work, we need a host to appear only once in the table */
                        /* THIS MEANS THAT THIS CODE WORKS FOR ONLY SINGLE SOURCE CLUSTER */
                        /* A possible workaround is installing the metadata and the event on
                           diferent databases. Then activate the event selectively.
                           WARNING: This solution hasn't been tested */
                        SELECT node_priority
                        INTO my_priority
                        FROM source_cluster
                        WHERE cluster LIKE '%'
                        AND node_name=old_source_host;

                        /* We return the following priority value, we are not using always
                        the node with the higher priority because we don't know if it
                        is available. We will test replication in a cycle. */
                        SELECT ( my_priority ) % count(*) + 1 
                        INTO counter_variable
                        FROM replica_cluster
                        WHERE cluster=cluster_name;

                        /* Once we have the priority, we retrieve the host that has
                        that priority */
                        SELECT node_name
                        INTO new_source_host
                        FROM source_cluster
                        WHERE cluster LIKE '%'
                        AND node_priority = counter_variable;

                        SET @message =  CONCAT('This is the new source: ', new_source_host);
                        IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                        /* Lets retrieve the replication configuration we need to proceed. */
                        SELECT meta_value
                        INTO replication_user
                        FROM replication_metadata
                        WHERE meta_key = 'replication_user';

                        SELECT meta_value
                        INTO replication_password
                        FROM replication_metadata
                        WHERE meta_key = 'replication_password';

                        SELECT meta_value
                        INTO replication_ssl
                        FROM replication_metadata
                        WHERE meta_key = 'replication_ssl';

                        SET @message =  CONCAT('Replication_user: ', replication_user,', replication_ssl:', replication_ssl);
                        IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

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

                        SET @message =  CONCAT('Replication Started');
                        IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
                     ELSE
                        SET @message =  CONCAT('IO Thread is stopped, but pending transactions detected. Delaying failover.');
                        IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
                     END IF;
                  END IF;
               ELSE
                  /* Replication is running */
                  SET @message =  CONCAT('Replication is running. We do nothing.');
                  IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
               END IF;
            ELSE
               /* If counter_variable is not equal to my_priority, this means that we've found
               a server with higher priority and we need to make sure we're not replicating */
               SET @message =  CONCAT('Clear replication: server active with better priority');
               IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

               SELECT count('x')
               INTO counter_variable
               FROM performance_schema.replication_connection_status
               WHERE channel_name = replication_channel;

               IF counter_variable != 0 THEN

                  SET @message =  CONCAT('Stopping and unconfiguring replication.');
                  IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

                  SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
                  PREPARE stmt FROM @cmd;
                  EXECUTE stmt;
                  DROP PREPARE stmt;

                  SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
                  PREPARE stmt FROM @cmd;
                  EXECUTE stmt;
                  DROP PREPARE stmt;
               ELSE
                  SET @message =  CONCAT('There is no replication configured. Safe to exit.');
                  IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
               END IF;

            END IF;
         ELSE
            /* I'm not a replica, or at least I'm not in the configuration as a replica... I stop replication just in case */
            
            SET @message =  CONCAT('I\'m not a replica. Verifying that replication is not running.');
            IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

            SELECT count('x')
            INTO counter_variable
            FROM performance_schema.replication_connection_status
            WHERE channel_name = replication_channel;

            IF counter_variable != 0 THEN

               SET @message =  CONCAT('Stopping and unconfiguring replication.');
               IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

               SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
               PREPARE stmt FROM @cmd;
               EXECUTE stmt;
               DROP PREPARE stmt;

               SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
               PREPARE stmt FROM @cmd;
               EXECUTE stmt;
               DROP PREPARE stmt;
            ELSE
               SET @message =  CONCAT('There is no replication configured. Safe to exit.');
               IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
            END IF;
         END IF;
      ELSE
         /* I'm a master... I stop replication just in case */
         SET @message =  CONCAT('I\'m member of the master cluster. Verifying that replication is not running.');
         IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

         SELECT count('x')
         INTO counter_variable
         FROM performance_schema.replication_connection_status
         WHERE channel_name = replication_channel;

         IF counter_variable != 0 THEN

            SET @message =  CONCAT('Stopping and unconfiguring replication.');
            IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;

            SET @cmd = CONCAT('STOP SLAVE FOR CHANNEL \'',replication_channel,'\'');
            PREPARE stmt FROM @cmd;
            EXECUTE stmt;
            DROP PREPARE stmt;

            SET @cmd = CONCAT('RESET SLAVE ALL FOR CHANNEL \'',replication_channel,'\'');
            PREPARE stmt FROM @cmd;
            EXECUTE stmt;
            DROP PREPARE stmt;
         ELSE
            SET @message =  CONCAT('There is no replication configured. Safe to exit.');
            IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
         END IF;

      END IF;
   ELSE
      SET @message =  CONCAT('The cluster is not healthy or I\'m not member of a cluster.');
      IF logging THEN EXECUTE poor_man_logger USING @level,@message; END IF;
   END IF;
   DROP PREPARE poor_man_logger;
END //

DELIMITER ;
