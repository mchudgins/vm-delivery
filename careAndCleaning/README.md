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

Scaling of the cluster involves balancing the availability, resiliency, latency, throughput, and cost of the cluster.
This makes determining the optimum size of the cluster and the nodes within the cluster a linear optimization
for each specific, combined workload on the cluster.

### Development Cluster
As a result, a highly complex scale out procedures _could_ be defined to maximize the attributes of cluster,
however this procedure, in the spirit of agile development, will assume that node sizes
may be held relatively constant.
In other words, let us assume that:
    
    1.  when running the cluster under its minimum workload that only two nodes
    of equivalent size in the private subnet(s) are required; and, that these node sizes are less than the maximum
    node size available from the cloud provider.
    
    2.  that the relative cost of a node is constant with respect to the resources within it;
    in other words, that a node with 2 cpus is twice as expensive as a node with one cpu.
    
Therefore, each scale out event should attempt to increase the node size whenever possible, so long as increasing
the node size does not increase the _blast radius_.

### Production Cluster

In a production cluster there will be an increased emphasis on availability.
Therefore, we will attempt to minimize the excess application capacity by
increasing the number of nodes.

Finally, proving the viability and correctness of the production cluster's
scale out algorithm is of critical importance.  The production cluster's
scale out algorithm should be used within the development cluster
prior to deployment to production on a regular basis.

### Dependencies
A working cluster with at least two nodes in the public subnet(s) and two nodes in the private subnet(s).

### Procedure

Net CPU & network utilization should be monitored.  As either one of these
metrics is measured to be 70% over a configurable time interval, a new node
should be spun up.  Memory utilization over 80% over a configurable time interval
should result in a new instance being spun up.


## Cluster Scale In

### Dependencies

A working cluster larger than the minimum cluster size.

### Procedure

Hysteresis must be used.
When ALL three of the CPU, network utilization, and memory metrics fall
below the (trigger levels - _N_) of a scale out event for a configurable time interval,
one instance of cluster should be selected for the scale in process.

The scale in process must first initiate the node's _evacuation process_,
then terminate the instance.

## Cluster Hygiene -- Lease Expiration

All resources within the cluster must be tagged with a lease expiration
date time.  Any resource in the development cluster that exists
beyond it's expiration time must be removed during a _nightly_ cleaning process.

## Cluster Hygiene -- Rotation

Nodes within the cluster should be rotated.  No node (etcd, master, node) should
live longer than a configurable time period (this time period should be hours or days
rather than weeks or months).

## Cluster Hygiene -- Upgrade

Cluster upgrades must use a canary, incremental deployment process for upgrades
in order to minimize impact for the users of the cluster.
