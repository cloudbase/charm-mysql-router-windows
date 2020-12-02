# Overview

This MySQL router charm provides a [MySQL 8 Router](https://dev.mysql.com/doc/mysql-router/8.0/en/) for Windows. It proxies database requests from an application to a MySQL 8 InnoDB cluster.

It is a subordinate charm that is used in conjunction with the [mysql-innodb-cluster](https://jaas.ai/mysql-innodb-cluster) charm. Starting with Ubuntu Focal, the [percona-cluster](https://jaas.ai/percona-cluster) is no longer available, meaning you will need to use MySQL router to integrate with any application that requires the ```shared-db``` relation with MySQL.

# Usage

This is a subordinate charm that provides ```shared-db```, and consumes ```mysql-router```. Your charm does not need any changes to work with this charm. You simply need to deploy it and add the ```shared-db``` relation as you normally would.

```bash
juju deploy ./mysql-router

juju add-relation mysql-innodb-cluster:db-router mysql-router:db-router
juju add-relation your-charm:shared-db mysql-router:shared-db
```

