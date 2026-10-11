'use strict';

const crypto = require('crypto');
const storage = require('./storage');
const { USER_AVATARS } = require('../utils/constants');

const isConfigured = storage.isConfigured;

const EXTENSIONS = Object.freeze({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
});

function buildPath(userId, mimeType) {
  const ext = EXTENSIONS[mimeType];
  if (!ext) throw new Error('unsupported_mime');
  return `${USER_AVATARS.pathPrefix}/${userId}/${Date.now()}_${crypto.randomBytes(16).toString('hex')}.${ext}`;
}

function pathBelongsToUser(path, userId) {
  return typeof path === 'string' && path.startsWith(`${USER_AVATARS.pathPrefix}/${userId}/`) && !path.includes('..');
}

function isAvatarPath(path) {
  return typeof path === 'string' && path.startsWith(`${USER_AVATARS.pathPrefix}/`);
}

const createUploadUrl = ({ userId, mimeType }) =>
  storage.createUploadUrl(USER_AVATARS.bucket, buildPath(userId, mimeType));

const createViewUrl = (path) =>
  storage.createViewUrl(USER_AVATARS.bucket, path, {
    expiresInSeconds: USER_AVATARS.viewUrlSeconds,
  });

const statObject = (path) => storage.statObject(USER_AVATARS.bucket, path);

const remove = (path) => storage.remove(USER_AVATARS.bucket, path);

module.exports = {
  isConfigured,
  buildPath,
  pathBelongsToUser,
  isAvatarPath,
  createUploadUrl,
  createViewUrl,
  statObject,
  remove,
};
