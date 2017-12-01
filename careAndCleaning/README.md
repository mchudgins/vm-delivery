# Care & Cleaning of Your Openshift Origin Cluster

This document outlines the various evolutions of
an Openshift Origin cluster on the AWS platform.

## Cluster Bootstrap

### Dependencies
This evolution requires that an AWS account has been created
and joined to the DST master organization, IAM roles created,
and VPC, subnets, and security groups created independently
of the cluster.

### Procedure

1. Create the initial cluster configuration files and certificates.
    1. Launch, in the command & control subnet(s), an instance with appropriate permissions, to do the following:
    2. create, in the same region as the cluster, an S3 bucket dedicated to holding secrets for the bootstrapped cluster.
    3. generate the aforementioned Origin certificates and keys; 
    4. then store these in the S3 bucket.  
     
2. Launch, in the command and control subnet(s), a Vault instance backed by an S3 bucket.
Manual intervention required to _unseal_ the vault (To remove
the need for ssh access to the Vault instance, a _one-time-use_
web application may be required).

3. Store the secrets in the Vault instance and configure Vault for secure operation.
Launch, in the command and control subnet(s), an instance with appropriate permissions to READ the
cluster's secrets bucket and populate the Vault instance with the x509 keys
generated in step 2.  This step may be alternatively performed by a
startup script within the Vault instance once it has been unsealed.
Vault must be configured to use the [EC2 Authentication Method](https://www.vaultproject.io/docs/auth/aws.html).
The initial implementation of Vault may use an encrypted S3 bucket as its secure storage media.

4. Create, if necessary, a [Code Commit](https://aws.amazon.com/codecommit/) repository
in the same region as the cluster.  Push, from code.dstcorp.net,
the global configuration repo containing the master and node
configuration to the Code Commit repo.

5. Launch a Spring Cloud Config Server instance backed by
the Code Commit repository.

6. Launch, in the command and control subnet(s), the etcd cluster.
Wait for it to report as healthy
(presumes some code has been written and deployed
which reports on cluster health via a rest call).

7. Launch,  in the command and control subnet(s), the Openshift master(s).  Dev clusters will use only one master.
Prod clusters will use multiple masters.  Wait for the master
to initialize (check via a rest call to the master's health endpoint).

8. Launch, in the private subnet(s), one node instance.
Deploy the appropriate cluster initiation job (pod).
The initiation pod is likely to vary depending upon the cluster's use
as either a development cluster or a production controlled cluster.

    General outline of cluster initiation job:

    1. Modify default project template to deploy (only) to nodes in the private subnet.
    
    2. Launch one (or more) instances in the public subnet.  This means
    the job will need a k8s secret with sufficient AWS credentials to launch nodes.
    The k8s secret should be sourced from Vault.
    
    3. Deploy, explicitly, to the public node(s), HA proxy.
    
    4. Deploy, if desired, the Openshift Registry.
    
    5. Deploy any cluster hygiene pods (lease expiration, scale-out/scale-in, etc)
    
    6. Other administrative tasks, TBD.
    
    7. Deploy DST Application Templates.
    
    8. Deploy Infrastructure Services, TBD. Examples would be Openshift's metrics service,
    Kafka, Cassandra, Zipkin, Hystrix, Turbine, Prometheus,
    Vault, ConfigServer, etc. 
      

## Cluster Scale Out

## Cluster Scale In

## Cluster Hygiene -- Lease Expiration

## Cluster Hygiene -- Rotation

## Cluster Hygiene -- Upgrade