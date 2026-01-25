#!/bin/bash
# Archive all docker data with date
tar czf /srv/backups/docker-$(date +%F).tar.gz /srv/docker/data
